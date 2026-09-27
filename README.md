# Civil Schedule Expander

基于 **FastAPI + 标准库 zoneinfo** 的民用日程展开 API。输入 IANA 时区、日期区间、
星期集合与本地时刻，服务通过 **UTC 往返校验**区分正常 / 跳时（gap）/ 叠时（fold），
按指定策略生成**去重且按 UTC 稳定排序**的实例，并返回每个实例的本地时间、UTC 偏移、
UTC 时间与决策原因。`POST /overlaps` 在此基础上为两个日程各附加时长，
用**扫描线**检测它们在真实时间轴上的全部冲突；`POST /daily-occupancy`
则把单侧日程的占用区间合并后按**报告时区的本地日界**切分，逐日统计真实占用分钟数；
`POST /staffing-gaps` 在 UTC 窗口内扫描多名员工的上下岗事件，
输出在岗人数低于最低要求的缺员区间；`POST /rest-violations`
把同一员工的多条日程在真实 UTC 时间轴上合并为工作段，
检查相邻工作段之间的休息空档是否低于最低分钟数；
`POST /common-free-slots` 把每名参与者的忙碌区间合并后取窗口内的共同空闲，
按**以窗口起点为原点的步长网格**枚举能完整容纳预约的起止时刻；
`POST /schedule-changes` 对账同一员工**变更前后两版日程**，
在半开 UTC 窗口内比较两版工作时间集合，
输出**取消与新增的最大连续区间**、每段真实分钟数及两类总分钟数。

## 快速启动（单条命令）

```bash
docker compose up --build
```

依赖（FastAPI / uvicorn / tzdata）在镜像构建时安装完毕，容器启动即可服务。

- 服务地址： http://localhost:8000
- 交互式文档（Swagger UI）： http://localhost:8000/docs
- 健康检查： http://localhost:8000/health
- 接口（均为 POST，端口同上）： `/expand`、`/overlaps`、`/daily-occupancy`、`/staffing-gaps`、`/rest-violations`、`/common-free-slots`、`/schedule-changes`

## 配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `8000` | 宿主机映射端口，如 `PORT=9000 docker compose up --build` 后访问 http://localhost:9000 |

容器内服务固定监听 8000 端口，无需其他配置；时区数据库由镜像内系统 tzdata
及 pip 包 `tzdata`（兜底）提供。

## API

### `POST /expand`

请求体：

```json
{
  "timezone": "Europe/Berlin",
  "start_date": "2026-03-28",
  "end_date": "2026-03-30",
  "weekdays": [5, 6, 0],
  "local_time": "02:30",
  "gap_strategy": "shift_forward",
  "fold_strategy": "both"
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `timezone` | string | IANA 时区名，如 `America/New_York` |
| `start_date` / `end_date` | date | 日期区间（两端均含） |
| `weekdays` | int[] | 星期集合，`0`=周一 … `6`=周日，至少 1 个 |
| `local_time` | string | 本地时刻，如 `02:30` |
| `gap_strategy` | string | 不存在时刻策略：`skip`（默认，跳过）/ `shift_forward`（按跳变差值前移） |
| `fold_strategy` | string | 重复时刻策略：`first`（默认，取第一次）/ `second`（取第二次）/ `both`（两次都保留） |

响应 `200`：

```json
{
  "timezone": "Europe/Berlin",
  "count": 3,
  "skipped_count": 0,
  "skipped_dates": [],
  "instances": [
    {"local": "2026-03-28T02:30:00+01:00", "offset": "+01:00", "utc": "2026-03-28T01:30:00Z", "reason": "normal"},
    {"local": "2026-03-29T03:30:00+02:00", "offset": "+02:00", "utc": "2026-03-29T01:30:00Z", "reason": "gap_shifted_forward"},
    {"local": "2026-03-30T02:30:00+02:00", "offset": "+02:00", "utc": "2026-03-30T00:30:00Z", "reason": "normal"}
  ]
}
```

决策原因（`reason`）：

| 值 | 含义 |
| --- | --- |
| `normal` | 正常时刻，本地时间与 UTC 一一对应 |
| `gap_shifted_forward` | 原时刻不存在（春跳），已按跳变差值前移 |
| `fold_first` | 重复时刻（秋回），取第一次出现（UTC 较早） |
| `fold_second` | 重复时刻（秋回），取第二次出现（UTC 较晚） |

被 `skip` 策略跳过的日期不计入 `instances`，汇总在 `skipped_count` / `skipped_dates`。

### `POST /overlaps`

判断两个民用周期日程在真实时间轴上的冲突。请求体的 `a` / `b` 两侧各自携带
与 `/expand` 相同的展开参数（含各自的 `gap_strategy` / `fold_strategy`），外加
`duration_minutes`；两侧独立展开后，把每个实例解释为**半开 UTC 区间**
`[start, start+duration)`，用扫描线枚举全部跨侧重叠。**边界相接不算冲突**
（一侧终点等于另一侧起点时重叠为空）。

请求体：

```json
{
  "a": {
    "timezone": "Europe/Berlin",
    "start_date": "2026-03-02",
    "end_date": "2026-03-02",
    "weekdays": [0],
    "local_time": "09:00",
    "duration_minutes": 60
  },
  "b": {
    "timezone": "America/New_York",
    "start_date": "2026-03-02",
    "end_date": "2026-03-02",
    "weekdays": [0],
    "local_time": "03:30",
    "duration_minutes": 60
  }
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `a` / `b` | object | 一侧日程：全部 `/expand` 请求字段 + `duration_minutes` |
| `duration_minutes` | int | 每次实例的时长（分钟），`1`～`1440` |

响应 `200`（`overlaps` 按 `overlap_start_utc` 排序）：

```json
{
  "count": 1,
  "overlaps": [
    {
      "a_start_utc": "2026-03-02T08:00:00Z",
      "b_start_utc": "2026-03-02T08:30:00Z",
      "overlap_start_utc": "2026-03-02T08:30:00Z",
      "overlap_end_utc": "2026-03-02T09:00:00Z",
      "minutes": 30.0
    }
  ]
}
```

| 字段 | 说明 |
| --- | --- |
| `a_start_utc` / `b_start_utc` | 两侧实例起点（UTC，Z 结尾） |
| `overlap_start_utc` / `overlap_end_utc` | 重叠区间起止（半开，UTC） |
| `minutes` | 重叠时长（分钟） |

每侧的日期区间同样限制为不超过 366 天，校验失败返回 422。

### `POST /daily-occupancy`

统计单个日程在报告时区内的逐日占用时长。请求体与 `/overlaps` 单侧相同
（全部 `/expand` 展开参数 + `duration_minutes`），外加 `report_timezone`。
实例按既有策略展开后，每个实例解释为**半开 UTC 区间**
`[start, start+duration)`；先**合并相交或相接的区间**（重复时刻产生的
重叠只计一次），再按报告时区的**本地日界**切分，逐日返回占用的真实分钟数。
跨午夜自然落到相邻两日；夏令时切换日（23 / 25 小时）仍按实际 UTC 流逝累计。
无实例时 `days` 为空列表。

请求体：

```json
{
  "timezone": "America/New_York",
  "start_date": "2026-03-07",
  "end_date": "2026-03-07",
  "weekdays": [5],
  "local_time": "23:00",
  "duration_minutes": 180,
  "report_timezone": "America/New_York"
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| （展开参数） | — | 与 `/expand` 请求字段相同，校验规则一致 |
| `duration_minutes` | int | 每次实例的时长（分钟），`1`～`1440` |
| `report_timezone` | string | 报告时区（IANA 名），按该时区的本地日界切分 |

响应 `200`（`days` 按日期升序）：

```json
{
  "report_timezone": "America/New_York",
  "count": 2,
  "days": [
    {"date": "2026-03-07", "minutes": 60.0},
    {"date": "2026-03-08", "minutes": 120.0}
  ]
}
```

上例中实例为纽约 2026-03-07 23:00 EST（= 03-08 04:00 UTC）起 180 分钟，
跨越春跳（03-08 当日仅 23 小时），仍按真实 UTC 时长计入两日。

| 字段 | 说明 |
| --- | --- |
| `report_timezone` | 报告时区 |
| `count` | 有占用的天数 |
| `days[].date` | 报告时区的本地日期（YYYY-MM-DD） |
| `days[].minutes` | 当日占用的真实分钟数 |

### `POST /staffing-gaps`

在 UTC 窗口内查询在岗人数低于最低要求的缺员区间。每名员工携带**可为空**的
日程列表（`schedules`，与 `/overlaps` 单侧参数与校验完全一致）；各日程按既有
跳时 / 叠时策略展开后，实例按真实时长解释为**半开 UTC 区间**
`[start, start+duration)` 并**裁剪到窗口**。同一员工相交或相接的区间先合并
（同一员工只计一人），再按时间扫描全部上下岗事件（**同一时刻的事件一起处理**）。
输出人数不足的非空区间；**在岗集合相同的相邻缺员段合并**，结果按起点排序；
全程达标时返回空列表。

请求体：

```json
{
  "window_start_utc": "2026-03-02T00:00:00Z",
  "window_end_utc": "2026-03-03T00:00:00Z",
  "min_staff": 2,
  "employees": [
    {
      "id": "alice",
      "schedules": [
        {
          "timezone": "Europe/Berlin",
          "start_date": "2026-03-02",
          "end_date": "2026-03-02",
          "weekdays": [0],
          "local_time": "09:00",
          "duration_minutes": 60
        }
      ]
    },
    {
      "id": "bob",
      "schedules": [
        {
          "timezone": "America/New_York",
          "start_date": "2026-03-02",
          "end_date": "2026-03-02",
          "weekdays": [0],
          "local_time": "03:30",
          "duration_minutes": 60
        }
      ]
    },
    {"id": "carol", "schedules": null}
  ]
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `window_start_utc` / `window_end_utc` | string | 查询窗口起止（半开），UTC ISO 8601 且**以 `Z` 结尾**；须递增且不超过 366 天 |
| `min_staff` | int | 最低在岗人数，`1`～员工总数 |
| `employees` | object[] | `1`～`20` 名员工，`id` 唯一 |
| `employees[].id` | string | 员工唯一 ID |
| `employees[].schedules` | object[] \| null | 日程列表（与 `/overlaps` 单侧相同）；`null` 或空列表表示无排班 |

响应 `200`（`gaps` 按 `start_utc` 排序）：

```json
{
  "count": 4,
  "gaps": [
    {"start_utc": "2026-03-02T00:00:00Z", "end_utc": "2026-03-02T08:00:00Z", "on_duty": [], "missing": 2},
    {"start_utc": "2026-03-02T08:00:00Z", "end_utc": "2026-03-02T08:30:00Z", "on_duty": ["alice"], "missing": 1},
    {"start_utc": "2026-03-02T09:00:00Z", "end_utc": "2026-03-02T09:30:00Z", "on_duty": ["bob"], "missing": 1},
    {"start_utc": "2026-03-02T09:30:00Z", "end_utc": "2026-03-03T00:00:00Z", "on_duty": [], "missing": 2}
  ]
}
```

上例中 alice 在岗 `[08:00, 09:00)` UTC、bob 在岗 `[08:30, 09:30)` UTC、carol 无排班；
仅 `[08:30, 09:00)` 达到 `min_staff=2`，其余时段按缺员输出。

| 字段 | 说明 |
| --- | --- |
| `count` | 缺员区间数 |
| `gaps[].start_utc` / `gaps[].end_utc` | 缺员区间起止（半开，UTC，Z 结尾） |
| `gaps[].on_duty` | 区间内在岗员工 ID，升序（可能为空列表） |
| `gaps[].missing` | 缺少人数（`min_staff` − 在岗人数） |

### `POST /rest-violations`

检查同一员工相邻工作段之间的休息是否低于最低分钟数。请求体携带该员工的
**一组日程**（`schedules`，与 `/overlaps` 单侧参数与校验完全一致，各含
`duration_minutes`）与 `min_rest_minutes`。各日程按既有跳时 / 叠时策略展开后，
实例按真实时长解释为**半开 UTC 区间** `[start, start+duration)`，并在真实 UTC
时间轴上**合并所有相交或相接的工作区间**（连续工作合并为一段，不产生空档，
故休息时长恒为正、不会出现负休息）。随后**仅比较相邻工作段之间的空档**，
返回严格低于阈值的空档：起止 UTC、实际休息分钟与差额，按起点排序。
跨时区与夏令时切换均按真实经过时间计算（如春跳当日钟面 3 小时仅为真实 2 小时）。

请求体：

```json
{
  "schedules": [
    {
      "timezone": "Europe/Berlin",
      "start_date": "2026-03-02",
      "end_date": "2026-03-02",
      "weekdays": [0],
      "local_time": "09:00",
      "duration_minutes": 240
    },
    {
      "timezone": "America/New_York",
      "start_date": "2026-03-02",
      "end_date": "2026-03-02",
      "weekdays": [0],
      "local_time": "08:00",
      "duration_minutes": 60
    }
  ],
  "min_rest_minutes": 90
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `schedules` | object[] | 日程列表（与 `/overlaps` 单侧相同），至少 1 条 |
| `min_rest_minutes` | int | 相邻工作段之间的最低休息分钟数，`>= 1` |

响应 `200`（`violations` 按 `start_utc` 排序）：

```json
{
  "min_rest_minutes": 90,
  "count": 1,
  "violations": [
    {
      "start_utc": "2026-03-02T12:00:00Z",
      "end_utc": "2026-03-02T13:00:00Z",
      "rest_minutes": 60.0,
      "shortfall_minutes": 30.0
    }
  ]
}
```

上例中柏林 09:00 CET = 08:00 UTC 工作 240 分钟（至 12:00 UTC），
纽约 08:00 EST = 13:00 UTC 工作 60 分钟；两段之间真实空档
`[12:00, 13:00)` UTC 仅 60 分钟，低于阈值 90，差额 30 分钟。

| 字段 | 说明 |
| --- | --- |
| `min_rest_minutes` | 最低休息分钟数阈值 |
| `count` | 休息不足的空档数 |
| `violations[].start_utc` / `violations[].end_utc` | 空档起止（半开：起点为上一工作段终点，终点为下一工作段起点），UTC，Z 结尾 |
| `violations[].rest_minutes` | 实际休息分钟数（真实 UTC 流逝） |
| `violations[].shortfall_minutes` | 休息差额（`min_rest_minutes` − `rest_minutes`） |

空档恰好等于阈值不算违规；所有空档均达标（或工作段不足两段）时
`violations` 为空列表。

### `POST /common-free-slots`

在半开 UTC 窗口 `[window_start_utc, window_end_utc)` 内查询 **1～10 名参与者**
共同空闲、且能完整容纳一次预约的全部网格起点。每名参与者携带**可为空**的
日程列表（`schedules`，与 `/overlaps` 单侧参数与校验完全一致）；`null` 或
空列表表示该参与者**全程空闲**。各日程按既有跳时 / 叠时策略展开后，实例按
真实时长解释为**半开 UTC 区间** `[start, start+duration)`；同一参与者相交或
相接的忙碌段先合并（**重复实例不重复占用**），再取全体忙碌并集，窗口减去
并集即为共同空闲段。以**窗口起点为步长网格原点**（步长 `step_minutes`），
仅返回能完整容纳 `[t, t+duration_minutes)` 的网格起点 `t` 及对应终点
（**边界相接允许预约**），结果按 UTC 升序。

请求体：

```json
{
  "window_start_utc": "2026-03-02T08:00:00Z",
  "window_end_utc": "2026-03-02T12:00:00Z",
  "duration_minutes": 30,
  "step_minutes": 30,
  "participants": [
    {
      "schedules": [
        {
          "timezone": "Europe/Berlin",
          "start_date": "2026-03-02",
          "end_date": "2026-03-02",
          "weekdays": [0],
          "local_time": "09:00",
          "duration_minutes": 60
        }
      ]
    },
    {
      "schedules": [
        {
          "timezone": "America/New_York",
          "start_date": "2026-03-02",
          "end_date": "2026-03-02",
          "weekdays": [0],
          "local_time": "03:30",
          "duration_minutes": 60
        }
      ]
    },
    {"schedules": null}
  ]
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `window_start_utc` / `window_end_utc` | string | 查询窗口起止（半开），UTC ISO 8601 且**以 `Z` 结尾**；须递增且不超过 31 天 |
| `duration_minutes` | int | 预约时长（分钟），`1`～`1440` |
| `step_minutes` | int | 网格步长（分钟），`1`～`1440`；网格原点为窗口起点 |
| `participants` | object[] | `1`～`10` 名参与者 |
| `participants[].schedules` | object[] \| null | 日程列表（与 `/overlaps` 单侧相同）；`null` 或空列表表示全程空闲 |

响应 `200`（`slots` 按 `start_utc` 升序）：

```json
{
  "count": 5,
  "slots": [
    {"start_utc": "2026-03-02T09:30:00Z", "end_utc": "2026-03-02T10:00:00Z"},
    {"start_utc": "2026-03-02T10:00:00Z", "end_utc": "2026-03-02T10:30:00Z"},
    {"start_utc": "2026-03-02T10:30:00Z", "end_utc": "2026-03-02T11:00:00Z"},
    {"start_utc": "2026-03-02T11:00:00Z", "end_utc": "2026-03-02T11:30:00Z"},
    {"start_utc": "2026-03-02T11:30:00Z", "end_utc": "2026-03-02T12:00:00Z"}
  ]
}
```

上例中柏林 09:00 CET = 08:00 UTC 忙碌 60 分钟、纽约 03:30 EST = 08:30 UTC
忙碌 60 分钟，忙碌并集为 `[08:00, 09:30)`；第三名参与者全程空闲。共同空闲
`[09:30, 12:00)` 内，以 08:00 为原点、30 分钟步长的网格起点 `09:30` 起
均可完整容纳 30 分钟预约（`11:30` 的终点与窗口终点相接，允许）。

| 字段 | 说明 |
| --- | --- |
| `count` | 可用预约槽数 |
| `slots[].start_utc` / `slots[].end_utc` | 预约槽起止（半开，UTC，Z 结尾），终点 = 起点 + `duration_minutes` |

### `POST /schedule-changes`

对账同一员工**变更前后两版日程**在半开 UTC 窗口
`[window_start_utc, window_end_utc)` 内的工作时间差异。`before` / `after`
均为**可为空**的日程列表（与 `/overlaps` 单侧参数与校验完全一致）；
`null` 或空列表表示该版本无排班。两版日程各自按既有跳时 / 叠时策略展开，
实例按真实时长解释为**半开 UTC 区间** `[start, start+duration)`，
**裁剪到窗口**后分别**合并相交或相接的区间**（重复实例不重复占用）。
随后比较两版工作时间集合：**取消段 = 变更前 − 变更后，新增段 = 变更后 − 变更前**，
均输出为**最大连续区间**，附每段真实分钟数与两类总分钟数，分别按起点排序。
**仅实例条目变化而工作覆盖不变**（如一段 120 分钟拆成两段相接的 60 分钟）时，
`cancelled` 与 `added` 均为空列表。

请求体：

```json
{
  "window_start_utc": "2026-03-02T00:00:00Z",
  "window_end_utc": "2026-03-03T00:00:00Z",
  "before": [
    {
      "timezone": "Europe/Berlin",
      "start_date": "2026-03-02",
      "end_date": "2026-03-02",
      "weekdays": [0],
      "local_time": "09:00",
      "duration_minutes": 60
    }
  ],
  "after": [
    {
      "timezone": "America/New_York",
      "start_date": "2026-03-02",
      "end_date": "2026-03-02",
      "weekdays": [0],
      "local_time": "03:30",
      "duration_minutes": 60
    }
  ]
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `window_start_utc` / `window_end_utc` | string | 查询窗口起止（半开），UTC ISO 8601 且**以 `Z` 结尾**；须递增且不超过 31 天 |
| `before` | object[] \| null | 变更前日程列表（与 `/overlaps` 单侧相同）；`null` 或空列表表示变更前无排班 |
| `after` | object[] \| null | 变更后日程列表（与 `/overlaps` 单侧相同）；`null` 或空列表表示变更后无排班 |

响应 `200`（`cancelled` / `added` 分别按 `start_utc` 排序）：

```json
{
  "cancelled_count": 1,
  "cancelled_total_minutes": 30.0,
  "cancelled": [
    {"start_utc": "2026-03-02T08:00:00Z", "end_utc": "2026-03-02T08:30:00Z", "minutes": 30.0}
  ],
  "added_count": 1,
  "added_total_minutes": 30.0,
  "added": [
    {"start_utc": "2026-03-02T09:00:00Z", "end_utc": "2026-03-02T09:30:00Z", "minutes": 30.0}
  ]
}
```

上例中变更前柏林 09:00 CET = `[08:00, 09:00)` UTC，变更后纽约 03:30 EST =
`[08:30, 09:30)` UTC；集合差得取消段 `[08:00, 08:30)` 与新增段
`[09:00, 09:30)`，各 30 分钟。

| 字段 | 说明 |
| --- | --- |
| `cancelled_count` / `added_count` | 取消 / 新增区间数 |
| `cancelled_total_minutes` / `added_total_minutes` | 取消 / 新增总真实分钟数 |
| `cancelled[]` / `added[]` | 取消 / 新增的最大连续区间，按起点排序；无差异时为空列表 |
| `start_utc` / `end_utc` | 差异区间起止（半开，UTC，Z 结尾） |
| `minutes` | 区间真实分钟数（UTC 流逝） |

### 错误（422）

以下情况返回 `422 Unprocessable Entity`：

- 非法 IANA 时区名（含 `/daily-occupancy` 的 `report_timezone`）
- `end_date` 早于 `start_date`（逆序区间）
- 区间超过 366 天（`(end_date - start_date).days > 366`，`/overlaps` 对每侧分别限制）
- `duration_minutes` 不在 1～1440（仅 `/overlaps` 与 `/daily-occupancy`）
- 星期值越界（不在 0–6）或集合为空等其他字段校验失败
- `/staffing-gaps`：窗口起止不是以 `Z` 结尾的 UTC 时刻、窗口未递增或超过 366 天、
  `min_staff` 不在 1～员工总数、员工数不在 1～20、员工 ID 重复
- `/rest-violations`：`schedules` 为空、`min_rest_minutes` 小于 1，
  或任一日程字段校验失败（规则与 `/overlaps` 单侧一致）
- `/common-free-slots`：窗口起止不是以 `Z` 结尾的 UTC 时刻、窗口未递增或
  超过 31 天、`duration_minutes` / `step_minutes` 不在 1～1440、
  参与者数不在 1～10，或任一参与者的日程字段校验失败
  （规则与 `/overlaps` 单侧一致）
- `/schedule-changes`：窗口起止不是以 `Z` 结尾的 UTC 时刻、窗口未递增或
  超过 31 天，或任一版本的日程字段校验失败（规则与 `/overlaps` 单侧一致）

## 判定原理

对每个候选本地时刻分别按 `fold=0` / `fold=1` 赋予时区，换算到 UTC 再换算回来
（UTC 往返校验）：能还原原时刻的解释才真实存在。两种解释均有效且 UTC 相同为正常；
均有效但 UTC 不同为叠时；均无效为跳时，跳变差值取两种解释对应的 UTC 之差，
`shift_forward` 即将本地时刻加上该差值后重新校验。所有实例按 UTC 去重
（保留先出现者）并按 UTC 稳定排序。

## 本地开发（不用 Docker）

```bash
pip install -r requirements.txt -r requirements-dev.txt
uvicorn app.main:app --reload        # http://localhost:8000
pytest                               # 运行测试
```

## 项目结构

```
app/
  main.py        # FastAPI 入口，/expand、/overlaps、/daily-occupancy、/staffing-gaps、/rest-violations、/common-free-slots、/schedule-changes 与 /health
  models.py      # 请求/响应模型与 422 校验规则
  scheduler.py   # UTC 往返校验分类 + 展开 / 去重 / 排序 + 扫描线重叠检测 + 逐日占用统计 + 在岗缺口扫描 + 休息违规检查 + 共同空闲预约槽枚举 + 排班变更集合差对账
tests/           # pytest 测试（核心逻辑 + API）
Dockerfile
docker-compose.yml
requirements.txt
requirements-dev.txt
```
