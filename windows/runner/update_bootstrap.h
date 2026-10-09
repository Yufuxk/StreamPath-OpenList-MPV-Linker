#pragma once

// 在 Flutter 加载前隔离更新事务并启动未提交事务的恢复。
bool StreamPathUpdateBootstrap();
