# `/v1/responses` 首输出专项治理

目标是将“首语义输出前断流”变成可定位、可灰度、可回滚的指标；不通过把网关超时提高到 120/600 秒来掩盖客户端或 CDN 的等待窗口。

## 观测基线

流式 `/v1/responses` 现在会在 Ops System Logs 持久记录一条 `component=stream_attempts`、`message=stream_attempt.completed` 事件。事件只含：网关请求 ID、CF-Ray、客户端类型分桶、请求体大小分桶、模型、选中账户 ID/平台/次数、上游响应头/首语义事件/首下游字节的相对毫秒、取消阶段和最终结果。

不会记录请求或响应正文、`Authorization`、API key、账户名、上游 URL 或原始 User-Agent。首输出前的取消也会写入此记录，即使它没有进入成功用量统计。

按 1 小时和 24 小时窗口，分别按 `client_type`、`model`、`selected_account_id`、`request_body_bucket` 聚合：

- 正常推理请求：首语义事件 TTFT P95 < 8 秒，P99 < 10 秒；高推理档位单独看板。
- `cancel_phase` 在 `before_upstream_headers` 或 `after_headers_before_semantic` 的占比：1 小时 < 0.5%，24 小时 < 0.2%。
- `upstream_response_headers_ms`、`first_semantic_event_ms`、`first_downstream_byte_ms` 分别显示，避免把上游等待和代理缓冲混为一谈。
- 上游响应头已到达时，灰度中的连续 5 秒窗口必须至少有一个下游 SSE 心跳或语义事件。

在数据库核对时可从 `ops_system_logs` 筛选 `component = 'stream_attempts'`，字段在 `extra` JSON 中；优先使用运维 UI/只读副本，避免在生产主库执行大范围 JSON 扫描。

## 受控链路隔离

使用 [stream-isolation-probe.sh](/Users/dhy/Desktop/github/sub2api/deploy/stream-isolation-probe.sh) 发送固定的合成流式请求。它不读取用户正文，也不会打印 API key。

公网基线：

```bash
PUBLIC_BASE_URL=https://api.example.com PROBE_API_KEY='…' \
  /Users/dhy/Desktop/github/sub2api/deploy/stream-isolation-probe.sh
```

只有在源站已经配置 mTLS、仅允许运维证书访问并且不公开 DNS/防火墙入口时，才追加受保护的直连比较：

```bash
PUBLIC_BASE_URL=https://api.example.com PROBE_API_KEY='…' \
ORIGIN_PROBE_URL=https://origin-probe.internal.example \
ORIGIN_PROBE_MTLS_REQUIRED=true \
ORIGIN_PROBE_CLIENT_CERT=/secure/path/client.crt \
ORIGIN_PROBE_CLIENT_KEY=/secure/path/client.key \
  /Users/dhy/Desktop/github/sub2api/deploy/stream-isolation-probe.sh
```

每次探针输出 `X-Request-ID`、响应 `CF-Ray`、HTTP 状态和 TTFB。用该请求 ID 关联 Gateway/Ops System Logs 和 Caddy access log；`CF-Ray` 则用于 Cloudflare 侧核对。直连与公网使用相同合成负载和独立请求 ID。

- 两路上游响应头都慢：重点排查账户/上游及账户健康评分。
- 直连快、公网慢：重点排查 Cloudflare 路径或客户端取消。
- 两路都在网关入站前慢：检查 Caddy、连接队列及大请求体读取。

## 灰度顺序与开关

1. 先保持 `GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED=false`、`GATEWAY_STREAM_KEEPALIVE_INTERVAL=0`，积累影子观测和隔离实验。
2. 就绪后在 10% 确定性请求 cohort 启用首输出预算：`GATEWAY_STREAM_KEEPALIVE_INTERVAL=5`、`GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED=true`、`GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT=10`。启用后账户健康熔断会为全部流式选路重排候选，但熔断账户仍保留为回退；只有 10 秒首输出预算受该 cohort 限制。
3. 连续 24 小时指标无回归后再扩大。心跳只在收到上游响应头后发出，能避免代理空闲断开，不能修复“上游响应头未到”。

首输出调度总预算为 10 秒：第一个候选账户最多 6 秒，第二个候选账户最多 4 秒。跨账户重放只允许尚未向客户端输出、没有 `tools`、没有 `previous_response_id`，并且携带 `Idempotency-Key` 的请求；其他请求只依靠账户健康路由避开慢账户。账户健康窗口按近 5/15 分钟 TTFT、首输出超时率和首语义输出前取消率熔断；熔断账户仍保留为容量不足时的后备。

任何阶段取消率、5xx 或重复计费上升时，立即设置：

```bash
GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED=false
GATEWAY_STREAM_KEEPALIVE_INTERVAL=0
```

并按 [rollback.sh](/Users/dhy/Desktop/github/sub2api/deploy/rollback.sh) 恢复原账户路由和上一健康容器。

## 请求体与资源治理

入口继续保留 `Content-Length`/现有最大请求体保护，并仅按大小分桶观测。后续针对 Codex 重复上下文、工具回填和附件在客户端做压缩或截断；服务端不得删除未知字段或用户正文。

运行基线为 2C2G：Gateway `896m`、`GOMEMLIMIT=640MiB`、`GOMAXPROCS=2`；Caddy `96m`、Postgres `320m`、Redis `128m`。总容器上限约 1.44GiB，给宿主页缓存和突发保留约 0.5GiB。

`deploy/deploy.sh` 默认 `DEPLOY_STRATEGY=auto`：主机内存低于约 3.5GiB 时自动使用受限重叠切换，而不是运行两个完整 `896m` Gateway。串行模式先以 `SERIAL_CANARY_MEMORY_LIMIT=256m` 无网络执行新镜像的 `--version` 校验；然后在同一上限启动可访问的候选容器并做本地和 Caddy 网络健康检查。仅在候选健康后才重载 Caddy，再等待 `SERIAL_DRAIN_SECONDS=15` 秒让已建立连接排水，停止旧 Gateway，最后把新实例提升至完整 `896m`。候选与旧实例重叠时的 Gateway cgroup 上限合计为 1152MiB；Caddy/Postgres/Redis 仍分别限制为 96/320/128MiB。发布前还要求 `MemAvailable` 不低于 `SERIAL_MIN_AVAILABLE_KB=524288`，不足时在切流前安全退出而不制造 502/503。旧容器保持停止状态，供 `rollback.sh previous` 使用。

内存充足的主机才使用蓝绿。上线前还必须验证云厂商控制台或堡垒机的备用入口：完成一次健康探测和回滚演练后，才允许推广流量。
