# 最小化窗口尺寸回归

先完成一次本项目的 Windows Flutter 构建，提供 `windows/flutter/ephemeral/` 下的引擎头文件和库，然后从项目根目录执行：

```powershell
cmake -S tools/acceptance/window_restore -B build/window-restore-artwork/native-tests
cmake --build build/window-restore-artwork/native-tests --config Release
ctest --test-dir build/window-restore-artwork/native-tests -C Release --output-on-failure
```

测试使用独立隐藏窗口与原生 `Win32Window`：最小化尺寸状态不得缩小已有内容窗口，恢复、最大化及普通调整尺寸必须继续同步客户区。最小化的收缩尺寸由测试模拟，不控制用户窗口、不访问应用数据，也不替代 Flutter 原生窗口的真实最小化／恢复验证。
