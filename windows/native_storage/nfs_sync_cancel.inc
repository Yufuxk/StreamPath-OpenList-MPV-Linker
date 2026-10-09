__declspec(dllexport) void
sp_nfs_set_cancel_cb(struct nfs_context *nfs, int (*callback)(void *), void *data)
{
        nfs->nfsi->sp_cancel_cb = callback;
        nfs->nfsi->sp_cancel_data = data;
}

