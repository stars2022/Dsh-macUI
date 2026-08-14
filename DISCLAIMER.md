# Disclaimer / 免责声明

## English

Dsh-macUI is an independent community project. It is not an official DeepSeek
product, is not endorsed by or affiliated with DeepSeek AI, and does not grant
any rights to the DeepSeek name, logo, or other trademarks. All product names
and trademarks belong to their respective owners.

DeepSeek Harness is an autonomous-agent runtime. Depending on the permission
preset and tools you enable, it may execute commands, read or modify files,
access networks, install software, or perform other consequential actions.
Review every workspace, model provider, plugin, permission preset, and proposed
operation before use. Keep backups and do not expose valuable credentials or
production systems to an untrusted model, plugin, device, or network.

The LAN launcher intentionally exposes the Harness Host API to other devices on
the local network. Use it only on a trusted private network and stop it after
testing. Never expose the plaintext LAN listener directly to the public
Internet.

The encrypted relay is experimental infrastructure, not a promise of complete
security. End-to-end payload encryption does not remove endpoint compromise,
traffic-analysis, availability, authentication-metadata, deployment, TLS, or
operational risks. A public deployment requires independent security review,
rate limiting, monitoring, backups, TLS termination, and applicable legal and
privacy compliance.

This repository is provided without warranty. You are solely responsible for
how you build, sign, deploy, configure, and use it, and for any resulting data
loss, service interruption, security incident, cost, or legal obligation.

## 中文

Dsh-macUI 是独立的社区项目，不是 DeepSeek 官方产品，未经 DeepSeek AI
背书，也与其不存在隶属关系。本项目不授予 DeepSeek 名称、图标或其他商标的
任何权利；相关产品名称和商标归各自权利人所有。

DeepSeek Harness 属于自主 Agent 运行环境。根据你启用的权限预设和工具，它可能
执行命令、读取或修改文件、访问网络、安装软件，或执行其他具有实际影响的操作。
使用前请审查工作区、模型提供方、插件、权限预设和具体操作，并保留可靠备份。不要
把重要凭据或生产环境交给不可信的模型、插件、设备或网络。

局域网启动脚本会主动把 Harness Host API 暴露给同一网络中的其他设备。它只能用于
可信私有网络，测试结束后应立即关闭；不得把明文局域网监听器直接暴露到公网。

加密中继仍属于实验性基础设施，不代表完整安全保证。端到端加密不能消除终端失陷、
流量分析、可用性、认证元数据、部署、TLS 和运维风险。任何公网部署都应另行进行
安全审计，并配置限流、监控、备份、TLS 终止及适用的法律与隐私合规措施。

本仓库按“现状”提供且不附带任何保证。构建、签名、部署、配置和使用方式，以及由此
产生的数据丢失、服务中断、安全事件、费用或法律义务，均由使用者自行承担。
