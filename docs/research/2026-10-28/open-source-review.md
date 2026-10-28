# 写轮眼相关开源源码研究 — 2026-10-28

研究基线：用户上传的 `7.11.9.4.3.2.6.17-RecordingSharingan-source.zip`。本轮只做源码审阅与静态验证，没有修改插件运行时代码、生成新DEB或进行真机测试。

## 结论与优先级

1. **原生矢量觉醒动画：最直接、许可明确。** Sharingan-Loader 的路径可借鉴到现有 UIKit/Core Animation 渲染中，普通勾玉与万花筒的路径命令结构一致。但原项目不提供可直接用于 SpringBoard 的生命周期管理，也没有证明连续路径插值。
2. **录屏快捷控制、自动免打扰：有具体系统调用入口，设备适配未验证。** Triggr 1.x 的 GPL 源码比旧录屏插件更适合作接口参考。免打扰必须设计恢复范围与用户手动变化处理，不能照搬“清空全部断言”。
3. **动作接口联动：可选扩展。** libtriggr 的公开仓库仅含MIT头文件、文档及示例，运行需要闭源Triggr2.x；不应宣传为完整开源方案。
4. 不推荐为凑功能整合旧的全局状态栏修改、系统视图强制移除或网页逐帧渲染。

## 1. Sharingan-Loader：矢量图案、勾玉出现、万花筒变化

- 项目：[Fury-2K/Sharingan-Loader](https://github.com/Fury-2K/Sharingan-Loader/tree/c8e3de994dcdf6716775e99540cf260ff0b5c9ff)
- 固定提交：`c8e3de994dcdf6716775e99540cf260ff0b5c9ff`
- 许可：完整MIT LICENSE，作者Manas Aggarwal。Package最低iOS14，但这是普通SwiftUI视图的部署条件，不代表越狱注入已兼容。
- 入口：`Sources/SharinganLoader/SharinganLoader.swift` 的 `SharinganLoader`、`addRotationAnimation`、`transformToMangekyou`；图形在 `TomoeView.swift` 的 `Tomoe.path(in:)`。
- 实现：以三个相同图形分别旋转、偏移、控制透明度；普通勾玉和万花筒使用不同坐标与尺寸。时序依赖5次 `Timer.scheduledTimer` 调用。

### 新发现与验证

- 去掉注释后，`Tomoe.path(in:)` 两种状态共用 **1次move + 2次二次贝塞尔曲线** 的结构。可将两组坐标转换为同结构CGPath，用于后续CAShapeLayer路径插值原型。这里只证明结构条件，未验证最终小尺寸视觉效果。
- 原Shape没有声明 `animatableData`。不能因为外层用了withAnimation，就声称其轮廓已实现连续变形。
- `shouldTransformToMangekyou=false` 仍会调用 `transformToMangekyou()`；它只限制后面的缩放弹跳，开关语义有缺陷。
- 没有找到onDisappear取消计时器或保存Timer句柄的处理；重复挂载不能照搬。测试文件只有空示例，未验证反复出现/消失。
- 外层使用全屏黑色背景及多层阴影，不能直接将完整SwiftUI加载器塞入当前录屏小容器。

### 接入建议（尚未实施）

保留当前挂载宿主，在自己的绘图子层中建立外圈、瞳孔、3个勾玉；只动画子层，不改变系统药丸frame、mask或cornerRadius。使用会话编号取消过期延迟任务。宿主迁移复用既有动画进度，真正新录屏才重置觉醒过程。

## 2. Triggr 1.x：录屏系统调用与免打扰

- [源码快照](https://github.com/Jond-ie/triggr/tree/3d8d916b1bfb5bff9def13790e79f1883689a621)
- 固定提交：`3d8d916b1bfb5bff9def13790e79f1883689a621`
- 许可：1.x GPL-3.0；README明确2.x以后闭源。不要将最新2.x功能清单误当作此GPL分支的已实现功能。
- 录屏入口：`Tweak/Tweak.x` 的 `TGScreenRecord`，动态取得RPScreenRecorder，运行时检查系统录屏状态、开始、停止选择器。源注释提到在iOS15.8观察到这些私有接口；没有本机iOS16.5验证证据。
- 免打扰入口：同文件 `TGSwitchFor` 的dnd分支，通过DNDModeAssertionService与DNDModeAssertionDetails读取/设置系统勿扰断言。

### 对写轮眼有用的功能方向

- 给录屏或写轮眼开关绑定按键、状态栏手势，减少进设置的步骤。
- 录屏开始后自动开启勿扰，结束时处理本次插件申请的状态。
- 可发布“录屏开始/结束”事件，供其他动作联动。当前写轮眼的capture-off宽限和尾部确认必须继续保留，避免抖动触发重复动作。

### 适配边界

- `TGScreenRecord`返回YES只代表已尝试调用；其回调忽略error，不代表录屏已启动或保存成功。新实现必须观察完成结果与真实状态。
- 源码开始录屏固定关闭麦克风；不能宣称保留用户录音设置。
- 免打扰关闭路径调用 `invalidateAllActiveModeAssertionsWithError:`。不能未经核对就用于自动恢复，否则可能干扰手动/其他来源的专注模式。
- 自动免打扰应明确所有权：录屏前已经启用时保持；录屏中用户改动时不粗暴还原；没有验证恢复范围前不交付自动切换。
- 当前写轮眼图层禁用触摸，不能直接绑手势就声称“双击眼睛”能用。独立动作入口与岛内手势命中是两项不同工作。

## 3. libtriggr：接口开源，运行引擎未在仓库中

- [源码快照](https://github.com/Jond-ie/libtriggr/tree/951deedd2c76194968f4d36092564541a15b3055)
- 许可：MIT，适用其头文件、文档、示例。
- 入口：`Triggr.h` 的 `registerAction:handler:`、`registerTrigger:`、`sendTrigger:`；README要求Triggr2.0及以上。
- 仓库未包含实际libtriggr运行引擎源码。完整录屏插件不能仅复制这个头文件就获得手势引擎。
- 可做可选动作接口：写轮眼开启/关闭/切换、暂停/继续旋转，且在库不存在时保持原功能；不应强制所有用户安装额外引擎。
- RootHide路径应使用jbroot，而不是硬编码/var/jb；接口文档已明确说明这一点。

## 4. Sharingan Designer：适合作编辑器，不适合直接放进岛内

- [源码快照](https://github.com/onlyil/sharingan-design/tree/02b6d751f6ce8f4b565cde017dacceccf7ef73f9)
- README声明MIT，审阅树中未见独立LICENSE全文；复用时需保留许可与归属信息。
- 实际绘图在 `app/design/components/preview-panel/sharingan-preview.tsx`；支持贝塞尔、圆、线、对称旋转。
- 发现其旋转每帧增加 `animationSpeed * 0.02`，然后requestAnimationFrame。它没有按时间差计算角速度；照搬会导致不同帧率下转速不同。
- 可以借鉴矢量编辑/对称逻辑；当前Core Animation旋转没有必要改为网页逐帧重绘。

## 5. VisibleIsland：不是安全的原生岛隐藏/扩宽模板

- [源码快照](https://github.com/ethxnn88/visibleisland/tree/85b14f94eb5e9e671daac6454928a6d6164649eb)
- 审阅仓库未找到明确许可证，因此不直接复制。
- `Tweak.xm` 修改SBSystemApertureWindow的transform/frame并包含旧刘海机型硬编码偏移。
- hideEnabled在 `_SBGainMapView.didMoveToWindow` 中直接removeFromSuperview，未看到对应重新插回的恢复路径。
- 无法从该实现推出“只隐藏空闲的岛”“安全扩宽录屏控制器”或“修复实体摄像头遮挡”。不用于替换当前稳定挂载逻辑。

## 6. ScreenRecording-Time：有计时入口，但旧状态栏实现不宜照搬

- [源码快照](https://github.com/h4ckua11/ScreenRecording-Time/tree/f6c99b9415bf3fb654f41ef9dc133f700c497c7d)
- 审阅仓库未找到明确许可证。
- `Tweak.xm` Hook RPScreenRecorder.recordingTimerDidUpdate: 获取录屏时间，用分布式通知刷新 _UIStatusBarStringView；以文本包含冒号判断时间字段。
- 这是旧系统状态栏方案，并非SystemAperture计时UI。选择器在iOS16.5是否仍有效未验证。
- 更适合研究录屏计时事件；不应把全局替换状态栏文字的逻辑整合进当前写轮眼。

## 7. DNDMyRecording：旧的录屏自动勿扰方案

- [源码快照](https://github.com/gilshahar7/DNDMyRecording/tree/70f933ee406cd77dd0c069a35a86492b1ff394fc)
- 审阅仓库未找到明确许可证。
- Hook RPScreenRecorder.setRecording:，开始前保存原勿扰状态，结束时若原来关闭则关闭勿扰。
- 读取UIApplication内部_dndNotificationsService/_currentState，属于脆弱私有成员；关闭仍使用全部断言清理。
- 功能构思直接相关，但不能原样整合。可用Triggr GPL1.x的运行时检查方式做新的接口适配，再单独验证所有权恢复。

## 当前6.17代码的新核对结果

- 基线Tweak.xm SHA256：`754c383e9c92b3e9f4bc8aaf92aaeed6d36853b6dce3e2f5775b401c47ed0a36`。
- `RSStartRotation`删除旧动画，从0到2π重新添加动画；`RSReloadEyeImage`和`RSSettingsChanged`会调用它。因此可以确认相关设置更新会重新建立零相位动画，但是否在手机上产生明显跳动尚未测试。
- `RSEyeViewEnsure`关闭交互；“点眼睛操作”不能只加手势识别器。
- `RSUpdateRecordingState`主要依据UIScreen.isCaptured，并对capture-off及恢复抖动做确认。新增觉醒/自动化/计时必须绑定真实会话生命周期，不能每次宿主layout或短暂capture变化都重启。

## 已做与未做

已做：7个仓库的指定源码审阅；固定提交与文件SHA256；矢量命令结构、计时器生命周期、帧率依赖和基线接入点的静态检查。

未做：真机运行、iOS16.5私有接口调用验证、图案小尺寸视觉验证、功能整合、云编译。不存在本轮“已实现”的新功能或新DEB。

所有快照及静态检查结果记录在同目录source-snapshots.json，后续优先复用本研究，避免重复搜索和重新包装旧结论。
