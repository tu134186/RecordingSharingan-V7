# RecordingSharingan 7.11.9.4.3.2.6.19

基于用户提供的6.17完整源码。新增独立的音乐音量模块（Crescendo GPL-3.0衍生），写轮眼挂载/素材逻辑保留。
设置 → 写轮眼 → 音乐音量控制 → 启用音量增强；长按正在播放音乐的灵动岛后拖动音量。锁屏音乐音量条可单独开启。新增模块默认关闭。

模块单独注入SpringBoard及MediaRemoteUI；原写轮眼仍只注入SpringBoard。未整合实验光圈6.18。
音量模块符号/选择器/通知/设置域已隔离为RSIV及com.tu.recordingsharingan.volume；保留上游布局、触控协调、失效状态过期处理。
不强链接MediaPlayer/AVFoundation，以运行时查找系统音量类。保留iOS16 arm64e class-ro兼容编译标志。

## 开源与修改
上游 https://github.com/Yves000/Crescendo ，commit 33c60a69d76454c268709b381ad987832403e534，作者Yves，GPL-3.0。
IslandVolume/、其设置组件及衍生文件按GPL-3.0提供，许可证位于IslandVolume/LICENSE及LICENSES/。
修改日期2026-10-28：命名空间隔离、独立设置域、默认关闭、统一入口、统一包版本。UPSTREAM.json包含原文件SHA256。
其余原有源码的权利归原作者；本模块以独立动态库及独立设置Bundle分发。

ShimaStyle仓库公开了通知实现，但此次审阅未找到许可证，且通知Hook跳过原系统分发，故没有复制或整合。K2geIsland仅作功能参考。

编译成功不等同于真机验证。待验证：音乐灵动岛展开音量拖动、硬件音量键、关闭开关恢复、锁屏音量、既有录屏及双眼素材。

构建兼容修正：子模块头文件使用相对路径；Logos %orig 先保存返回值，再传入高度计算；@try 中的 %orig 独占一行，避免预处理截断后续括号。
