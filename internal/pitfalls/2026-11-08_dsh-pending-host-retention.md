---
summary: A pending DSH turn retained its service across polling; avoid holding the service during host I/O and verify child-process exit.
---

# 未完成回合导致 DSH Host 留存

- 现象：隔离附件测试在 mock 模型无响应时结束，测试自己的 DSH Host 子进程脱离测试进程，临时目录也可能残留。
- 环境：macOS arm64，Apple Swift 6.4.2，DSH 0.2.2-rc.1；独立 DSH_HOME、本地 loopback 无服务的 mock provider。
- 尝试与证据：弱引用释放测试先失败后通过，见 `internal/evidence/2026-11-08_dsh-pending-service-leak-before.log`、`...dsh-pending-service-leak-after.log`；真实 Host 的服务释放、进程退出、重启后元数据回放和轮询完成回归见 `...dsh-file-lifecycle-final.log`。
- 根因：由服务持有的轮询任务虽以 weak self 捕获，但调用整个等待循环时又在异步等待期间强持有服务；未完成回合使服务和其 Host 无法释放。改为每次独立访问 Host 历史，仅在处理结果时短暂访问服务。
- 清理：按进程命令行和测试独有路径核对后终止三个本测试遗留的进程，并删除七个本测试独有 scratch 目录。测试自身现在先等待或结束已记录的子进程，再清理目录。
- 边界：验证了正常释放与测试轮询完成；不代表强制终止应用、物理断网、多窗口、远程主机或真实模型回合恢复均已验证。
