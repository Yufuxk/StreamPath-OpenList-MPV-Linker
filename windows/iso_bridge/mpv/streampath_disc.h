/* SPDX-License-Identifier: LGPL-2.1-or-later */
#pragma once
#include <windows.h>
#include <winhttp.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static volatile LONG64 sp_first_video_tick;

// 专用 MPV 每个进程只承载一个光盘会话。
void sp_remote_video_frame(void);
void sp_remote_video_frame(void)
{
    InterlockedCompareExchange64(&sp_first_video_tick, (LONG64)GetTickCount64(), 0);
}

struct sp_disc {
    HINTERNET session, connection;
    HANDLE cancel, interrupt;
    CRITICAL_SECTION lock;
    volatile LONG64 generation;
    uint64_t length;
    wchar_t path[64];
    volatile LONG media, failed;
    wchar_t *metrics_path;
    ULONGLONG started, first_overlay, input_started, input_latency_max;
    uint64_t input_count, input_completed, request_count, response_bytes;
    struct { uint64_t serial; ULONGLONG elapsed; bool completed; } inputs[256];
    uint64_t input_records;
};

static bool sp_disc_failed(struct sp_disc *d)
{
    return InterlockedCompareExchange(&d->failed, 0, 0) != 0;
}

static void sp_disc_finish_input(struct sp_disc *d, bool completed)
{
    if (!d->input_started) return;
    ULONGLONG elapsed = GetTickCount64() - d->input_started;
    size_t slot = (size_t)(d->input_records++ % 256);
    d->inputs[slot].serial = d->input_count;
    d->inputs[slot].elapsed = elapsed;
    d->inputs[slot].completed = completed;
    if (completed) {
        ++d->input_completed;
        if (elapsed > d->input_latency_max) d->input_latency_max = elapsed;
    }
    d->input_started = 0;
}

static void sp_disc_metrics(struct sp_disc *d)
{
    if (!d->metrics_path) return;
    size_t capacity = wcslen(d->metrics_path) + 5;
    wchar_t *temporary = malloc(capacity * sizeof(wchar_t));
    if (!temporary) return;
    swprintf(temporary, capacity, L"%ls.tmp", d->metrics_path);
    FILE *file = _wfopen(temporary, L"wb");
    if (!file) { free(temporary); return; }
    char overlay[32] = "null";
    char video[32] = "null", latency[32] = "null";
    LONG64 video_tick = InterlockedCompareExchange64(&sp_first_video_tick, 0, 0);
    if (video_tick > 0) snprintf(video, sizeof(video), "%llu",
        (unsigned long long)((ULONGLONG)video_tick - d->started));
    if (d->input_completed) snprintf(latency, sizeof(latency), "%llu",
        (unsigned long long)d->input_latency_max);
    if (d->first_overlay) snprintf(overlay, sizeof(overlay), "%llu",
        (unsigned long long)d->first_overlay);
    fprintf(file, "{\"schema\":1,\"mode\":\"webdavHdmvMenu\","
        "\"firstOverlayMs\":%s,\"firstVideoFrameMs\":%s,\"inputCount\":%llu,\"inputCompleted\":%llu,"
        "\"inputLatencyMaxMs\":%s,\"loopbackRequests\":%llu,"
        "\"loopbackBytes\":%llu,\"failed\":%s,\"inputSamplesDropped\":%llu,\"inputSamples\":[",
        overlay, video, (unsigned long long)d->input_count,
        (unsigned long long)d->input_completed, latency,
        (unsigned long long)d->request_count, (unsigned long long)d->response_bytes,
        sp_disc_failed(d) ? "true" : "false",
        (unsigned long long)(d->input_records > 256 ? d->input_records - 256 : 0));
    uint64_t first = d->input_records > 256 ? d->input_records - 256 : 0;
    for (uint64_t i = first; i < d->input_records; ++i) {
        size_t slot = (size_t)(i % 256);
        fprintf(file, "%s{\"serial\":%llu,\"elapsedMs\":%llu,\"completed\":%s}",
            i == first ? "" : ",", (unsigned long long)d->inputs[slot].serial,
            (unsigned long long)d->inputs[slot].elapsed,
            d->inputs[slot].completed ? "true" : "false");
    }
    fputs("]}", file);
    fclose(file);
    MoveFileExW(temporary, d->metrics_path, MOVEFILE_REPLACE_EXISTING);
    free(temporary);
}

static void sp_disc_overlay(struct sp_disc *d)
{
    if (!d) return;
    EnterCriticalSection(&d->lock);
    ULONGLONG now = GetTickCount64();
    bool changed = !d->first_overlay || d->input_started != 0;
    if (!d->first_overlay) d->first_overlay = now - d->started;
    sp_disc_finish_input(d, true);
    if (changed) sp_disc_metrics(d);
    LeaveCriticalSection(&d->lock);
}

static void sp_disc_state_changed(struct sp_disc *d)
{
    if (!d) return;
    EnterCriticalSection(&d->lock);
    if (d->input_started) {
        sp_disc_finish_input(d, true);
        sp_disc_metrics(d);
    }
    LeaveCriticalSection(&d->lock);
}

struct sp_request {
    HANDLE event, closed;
    DWORD expected, bytes, error;
};

static void CALLBACK sp_http_status(HINTERNET handle, DWORD_PTR context,
                                    DWORD status, void *info, DWORD length)
{
    (void)handle;
    (void)length;
    struct sp_request *r = (void *)context;
    if (!r) return;
    if (status == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING) {
        SetEvent(r->closed);
    } else if (status == WINHTTP_CALLBACK_STATUS_REQUEST_ERROR) {
        r->error = ((WINHTTP_ASYNC_RESULT *)info)->dwError;
        SetEvent(r->event);
    } else if (status == r->expected) {
        if (status == WINHTTP_CALLBACK_STATUS_READ_COMPLETE) r->bytes = length;
        SetEvent(r->event);
    }
}

static bool sp_wait(struct sp_disc *d, struct sp_request *r, BOOL started)
{
    if (!started && GetLastError() != ERROR_IO_PENDING) return false;
    HANDLE events[] = {d->cancel, d->interrupt, r->event};
    return WaitForMultipleObjects(3, events, FALSE, 30000) == WAIT_OBJECT_0 + 2 &&
           !r->error;
}

static bool sp_header(HINTERNET request, DWORD key, wchar_t *value, DWORD bytes)
{
    return WinHttpQueryHeaders(request, key, WINHTTP_HEADER_NAME_BY_INDEX,
                                value, &bytes, WINHTTP_NO_HEADER_INDEX);
}

static bool sp_transfer(struct sp_disc *d, void *destination,
                         uint64_t start, DWORD count, bool head)
{
    struct sp_request state = {0};
    ++d->request_count;
    state.event = CreateEventW(NULL, FALSE, FALSE, NULL);
    state.closed = CreateEventW(NULL, TRUE, FALSE, NULL);
    HINTERNET request = NULL;
    bool ok = false, callback_set = false;
    if (!state.event || !state.closed) goto done;
    request = WinHttpOpenRequest(d->connection, head ? L"HEAD" : L"GET",
        d->path, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    if (!request) goto done;
    DWORD_PTR context = (DWORD_PTR)&state;
    if (!WinHttpSetOption(request, WINHTTP_OPTION_CONTEXT_VALUE, &context, sizeof(context))) goto done;
    if (WinHttpSetStatusCallback(request, sp_http_status,
        WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES,
        0) == WINHTTP_INVALID_STATUS_CALLBACK) goto done;
    callback_set = true;
    DWORD disabled = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES |
                     WINHTTP_DISABLE_AUTHENTICATION;
    if (!WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled))) goto done;
    wchar_t headers[256];
    swprintf(headers, 256,
        L"Accept-Encoding: identity\r\nRange: bytes=%llu-%llu\r\n"
        L"X-StreamPath-Generation: %llu\r\nX-StreamPath-Phase: %ls\r\n",
        (unsigned long long)start, (unsigned long long)(start + count - 1),
        (unsigned long long)InterlockedCompareExchange64(&d->generation, 0, 0),
        InterlockedCompareExchange(&d->media, 0, 0) ? L"media" : L"metadata");
    state.expected = WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE;
    if (!sp_wait(d, &state, WinHttpSendRequest(request,
        headers, (DWORD)-1,
        WINHTTP_NO_REQUEST_DATA, 0, 0, context))) goto done;
    state.expected = WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE;
    if (!sp_wait(d, &state, WinHttpReceiveResponse(request, NULL))) goto done;
    DWORD status = 0, size = sizeof(status);
    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX) ||
        status != (head ? 200U : 206U)) goto done;
    wchar_t value[160], *end = NULL;
    if (!sp_header(request, WINHTTP_QUERY_CONTENT_LENGTH, value, sizeof(value))) goto done;
    uint64_t length = wcstoull(value, &end, 10);
    if (end == value || *end || length == 0) goto done;
    if (head) {
        if (length % 2048 != 0 || length > INT64_MAX) goto done;
        d->length = length;
        ok = true;
        goto done;
    }
    if (length != count) goto done;
    if (!sp_header(request, WINHTTP_QUERY_CONTENT_RANGE, value, sizeof(value))) goto done;
    wchar_t expected[160];
    swprintf(expected, 160, L"bytes %llu-%llu/%llu",
        (unsigned long long)start, (unsigned long long)(start + count - 1),
        (unsigned long long)d->length);
    if (wcscmp(value, expected)) goto done;
    DWORD filled = 0;
    while (filled < count) {
        state.expected = WINHTTP_CALLBACK_STATUS_READ_COMPLETE;
        state.bytes = 0;
        if (!sp_wait(d, &state, WinHttpReadData(request,
            (char *)destination + filled, count - filled, NULL)) ||
            state.bytes == 0 || state.bytes > count - filled) goto done;
        filled += state.bytes;
    }
    ok = true;
    d->response_bytes += count;
done:
    if (request) {
        WinHttpCloseHandle(request);
        // HANDLE_CLOSING 是最后一个回调，之后才能释放回调上下文。
        if (callback_set) WaitForSingleObject(state.closed, INFINITE);
    }
    if (state.event) CloseHandle(state.event);
    if (state.closed) CloseHandle(state.closed);
    return ok;
}

static void sp_disc_close(struct sp_disc *d)
{
    if (!d) return;
    sp_disc_finish_input(d, false);
    sp_disc_metrics(d);
    if (d->connection) WinHttpCloseHandle(d->connection);
    if (d->session) WinHttpCloseHandle(d->session);
    if (d->interrupt) CloseHandle(d->interrupt);
    DeleteCriticalSection(&d->lock);
    free(d->metrics_path);
    free(d);
}

static struct sp_disc *sp_disc_open(const char *url, HANDLE cancel, const char *metrics_path)
{
    unsigned port = 0;
    char token[33] = {0};
    int used = 0;
    if (sscanf(url, "http://127.0.0.1:%u/%32[0-9a-f]/disc.iso%n", &port, token, &used) != 2 ||
        used == 0 || url[used] || port == 0 || port > 65535 || strlen(token) != 32) return NULL;
    struct sp_disc *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    InitializeCriticalSection(&d->lock);
    d->started = GetTickCount64();
    InterlockedExchange64(&sp_first_video_tick, 0);
    if (metrics_path && metrics_path[0]) {
        int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, metrics_path, -1, NULL, 0);
        if (length <= 0) goto fail;
        d->metrics_path = malloc((size_t)length * sizeof(wchar_t));
        if (!d->metrics_path || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            metrics_path, -1, d->metrics_path, length)) goto fail;
    }
    d->cancel = cancel;
    d->generation = 1;
    d->interrupt = CreateEventW(NULL, TRUE, FALSE, NULL);
    swprintf(d->path, 64, L"/%hs/disc.iso", token);
    d->session = WinHttpOpen(L"StreamPath-Disc/1", WINHTTP_ACCESS_TYPE_NO_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
    if (!d->session || !d->interrupt) goto fail;
    WinHttpSetTimeouts(d->session, 1000, 1000, 30000, 30000);
    d->connection = WinHttpConnect(d->session, L"127.0.0.1", (INTERNET_PORT)port, 0);
    if (!d->connection || !sp_transfer(d, NULL, 0, 2048, true)) goto fail;
    return d;
fail:
    sp_disc_close(d);
    return NULL;
}

static void sp_disc_advance(struct sp_disc *d)
{
    if (!d) return;
    InterlockedIncrement64(&d->generation);
    SetEvent(d->interrupt);
    EnterCriticalSection(&d->lock);
    sp_disc_finish_input(d, false);
    ++d->input_count;
    d->input_started = GetTickCount64();
    // HEAD 只通知 helper 取消旧代际，不读取远端正文。
    ResetEvent(d->interrupt);
    if (!sp_disc_failed(d) && !sp_transfer(d, NULL, 0, 2048, true) &&
        WaitForSingleObject(d->cancel, 0) != WAIT_OBJECT_0) InterlockedExchange(&d->failed, 1);
    LeaveCriticalSection(&d->lock);
}

static int sp_disc_read(void *opaque, void *destination, int lba, int blocks)
{
    struct sp_disc *d = opaque;
    if (lba < 0 || blocks <= 0) return -1;
    uint64_t start = (uint64_t)lba * 2048;
    uint64_t bytes = (uint64_t)blocks * 2048;
    if (start >= d->length || bytes > d->length - start) return -1;
    EnterCriticalSection(&d->lock);
    ResetEvent(d->interrupt);
    bool ok = !sp_disc_failed(d) && WaitForSingleObject(d->cancel, 0) != WAIT_OBJECT_0;
    while (ok && bytes) {
        DWORD count = (DWORD)(bytes < 4194304 ? bytes : 4194304);
        ok = sp_transfer(d, destination, start, count, false);
        start += count;
        destination = (char *)destination + count;
        bytes -= count;
    }
    if (!ok && WaitForSingleObject(d->interrupt, 0) != WAIT_OBJECT_0 &&
        WaitForSingleObject(d->cancel, 0) != WAIT_OBJECT_0) InterlockedExchange(&d->failed, 1);
    LeaveCriticalSection(&d->lock);
    return ok ? blocks : -1;
}
