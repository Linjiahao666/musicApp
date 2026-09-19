# Store Server 文件与鉴权 API 调研

> 调研来源：`Linjiahao666/server` 仓库 README、`docs/prototype/api-contract.openapi.yaml`、`internal/auth/*`、`internal/files/*`、`migrations/*` 及集成测试。  
> 调研日期：2026-09-07  
> 关联 ticket：wayfinder #5

## 概述

Store Server 是单进程 Go 后端，鉴权与文件 API 同域部署。存储栈为 PostgreSQL（元数据与会话）+ Redis（Access Token JTI 黑名单）+ MinIO（对象存储）。所有受保护接口使用 RS256 JWT；文件下载额外使用短期 `file-access` JWT 并通过服务端 Range 代理。

默认基址：`http://localhost:8080`（Docker Compose 本地开发）。

## 鉴权流程

### 端点一览

| 方法 | 路径 | 认证 | 说明 |
|------|------|------|------|
| POST | `/v1/auth/register` | 无 | 用户注册 |
| POST | `/v1/auth/login` | 无 | 登录，返回 Access + Refresh Token |
| POST | `/v1/auth/refresh` | 无 | 用 Refresh Token 换取新 Access Token |
| POST | `/v1/auth/logout` | Bearer Access | 吊销 Access JTI 并失效 Refresh 会话 |
| GET | `/v1/auth/me` | Bearer Access | 当前用户信息 |
| GET | `/v1/auth/.well-known/jwks.json` | 无 | JWKS 公钥 |

### 凭证规则

| 凭证类型 | 算法 | TTL | 用途 |
|----------|------|-----|------|
| Access JWT | RS256 | **15 分钟**（`expires_in: 900`） | 所有需登录的 API |
| Refresh Token | 随机 32 字节 base64url | **7 天** | 换取新 Access Token |
| file-access JWT | RS256，`aud=file-access` | **5 分钟**（`expires_in: 300`） | 仅用于 `GET /v1/files/{file_id}/content` |

Access Token 含 `sub`（用户 UUID）、`jti`（用于 Redis 黑名单）。登出时将当前 Access 的 `jti` 写入 Redis，后续校验即拒绝。

Refresh Token 以 SHA-256 哈希存入 `sessions` 表；`POST /v1/auth/refresh` 返回**新 Access Token**，Refresh Token 本身不变。

### 注册与登录约束

- `username`：3–64 字符（按 Unicode 字符计数）
- `password`：至少 8 字符
- 用户名冲突：`409 AUTH_USERNAME_TAKEN`
- 凭证错误：`401 AUTH_INVALID_CREDENTIALS`

### 登出

`POST /v1/auth/logout` 需在 `Authorization: Bearer <access_token>` 下调用。请求体可携带 `refresh_token`（可选）；若提供且属于当前用户，对应 session 将被删除。

### 错误响应格式

```json
{
  "error": {
    "code": "AUTH_INVALID_TOKEN",
    "message": "access token is invalid or revoked"
  }
}
```

## 文件上传

### 路径选择：小文件直传 vs 分片上传

| 方式 | 端点 | 大小阈值 | 适用场景 |
|------|------|----------|----------|
| 小文件直传 | `POST /v1/files` | **≤ 10 MB**（10,485,760 字节） | 封面图、歌词文本等小文件 |
| 分片上传 | `POST /v1/files/uploads` + presigned PUT + complete | **> 10 MB** | MP3 音频等大文件 |

超过 10 MB 走小文件直传会返回 `413 FILE_TOO_LARGE`，消息为 `use multipart upload for files over 10MB`。

### 小文件直传 `POST /v1/files`

- **认证**：Bearer Access JWT
- **Content-Type**：`multipart/form-data`
- **字段**：
  - `file`（必填）：二进制文件
  - `content_type`（可选）：MIME 类型；未提供时取上传文件头的 `Content-Type`；仍为空则默认为 `application/octet-stream`
- **响应**：`201`，`FileResponse` 元数据

### 分片上传流程

**1. 发起** `POST /v1/files/uploads`

```json
{
  "filename": "track.mp3",
  "content_type": "audio/mpeg",
  "size_bytes": 12582912,
  "part_size_bytes": 8388608
}
```

| 字段 | 约束 |
|------|------|
| `filename` | 必填 |
| `content_type` | 必填 |
| `size_bytes` | 必填，**必须 > 10 MB** |
| `part_size_bytes` | 可选，默认 **8 MB**；最小 **5 MB**；分片数上限 **10,000** |

响应 `201`：

```json
{
  "upload_id": "<uuid>",
  "file_id": "<uuid>",
  "part_size_bytes": 8388608,
  "parts": [
    { "part_number": 1, "upload_url": "https://..." },
    { "part_number": 2, "upload_url": "https://..." }
  ]
}
```

presigned URL 有效期 **30 分钟**。客户端对每个 part 执行 **HTTP PUT** 直传 MinIO，记录响应头中的 `ETag`。

**2. 完成** `POST /v1/files/uploads/{upload_id}/complete`

```json
{
  "parts": [
    { "part_number": 1, "etag": "\"abc123\"" },
    { "part_number": 2, "etag": "\"def456\"" }
  ]
}
```

响应 `200`，返回 `FileResponse`。

**3. 放弃** `DELETE /v1/files/uploads/{upload_id}`

- 中止 MinIO multipart upload
- 将 upload 状态标为 `aborted`
- **删除**关联的 `files` 记录
- 响应 `204`

## 文件元数据

### 字段 `FileResponse`

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | UUID | 文件 ID |
| `owner_id` | UUID | 所有者用户 ID |
| `content_type` | string | 客户端声明的 MIME 类型 |
| `size_bytes` | int64 | 文件大小（分片上传在 initiate 时按声明值写入，complete 后不重新 stat） |
| `filename` | string | 原始文件名 |
| `created_at` | date-time | 创建时间 |

对象存储 key 格式：`files/{file_id}`，不对外暴露。

### 查询 `GET /v1/files/{file_id}`

- 需 Bearer Access JWT
- 仅文件所有者可访问；他人返回 `403 FILE_FORBIDDEN`
- 不存在返回 `404 FILE_NOT_FOUND`

## 文件下载：file-access JWT + Range 代理

### 签发下载凭证 `POST /v1/files/{file_id}/access-token`

- 需 Bearer Access JWT，且调用者必须是文件所有者
- 响应 `200`：

```json
{
  "access_token": "<file-access-jwt>",
  "token_type": "Bearer",
  "expires_in": 300
}
```

JWT 声明：`sub`（用户 ID）、`file_id`（绑定文件）、`aud: file-access`、`jti`（可黑名单）。

### 下载内容 `GET /v1/files/{file_id}/content`

- **必须使用 file-access JWT**，用户 Access JWT 无效（`401`）
- 可选 `Range` 请求头，支持：
  - `bytes=start-end`：闭区间字节范围
  - `bytes=start-`：从 start 到文件末尾
  - `bytes=-suffix`：文件末尾 suffix 字节
- 响应头：
  - 始终设置 `Accept-Ranges: bytes`
  - `Content-Type` 取自元数据中的 `content_type`
  - 有 Range：`206 Partial Content`，含 `Content-Range: bytes start-end/total` 与对应 `Content-Length`
  - 无 Range：`200`，`Content-Length` 为完整文件大小
- 非法 Range：`416 RANGE_NOT_SATISFIABLE`

### 推荐客户端流程

1. 用 Access JWT 调用 `POST /v1/files/{file_id}/access-token`
2. 用返回的 file-access JWT 请求 `GET /v1/files/{file_id}/content`，按需附加 `Range` 实现流式播放/断点续传
3. token 过期（5 分钟）后重新签发

## 删除语义

### 删除文件 `DELETE /v1/files/{file_id}`

- 需 Bearer Access JWT，仅所有者可操作
- 若存在 **pending** 状态的分片上传，先中止 MinIO multipart
- 从 MinIO 删除对象，再从 `files` 表删除记录
- 响应 `204`；之后 `GET` 元数据返回 `404`

### 放弃分片上传 `DELETE /v1/files/uploads/{upload_id}`

- 仅 `pending` 状态可中止；已完成或已中止返回 `400`
- 中止后 `files` 记录被删除，对应 `file_id` 不再可查

用户删除时级联：`users` 删除会级联删除 `files` 与 `uploads`（`ON DELETE CASCADE`）。

## Content-Type 约束

服务端**无 MIME 白名单**，由客户端声明并原样存储。

| 音乐客户端常见类型 | 建议 `content_type` | 推荐上传方式 |
|--------------------|---------------------|--------------|
| MP3 音频 | `audio/mpeg` | 通常 > 10 MB → 分片上传 |
| JPEG 封面 | `image/jpeg` | 通常 ≤ 10 MB → 小文件直传 |
| PNG 封面 | `image/png` | 小文件直传 |
| 歌词/文本 | `text/plain` | 小文件直传 |

下载时 `Content-Type` 响应头与元数据一致，浏览器或 `<audio>` 标签依赖此值；客户端上传时应传入正确 MIME。

## 数据库 schema 摘要

**`files`**：`id`、`owner_id`（FK users）、`object_key`、`content_type`、`size_bytes`、`filename`、`created_at`

**`uploads`**：`id`、`file_id`（FK files）、`owner_id`、`minio_upload_id`、`status`（`pending` / `completed` / `aborted`）、`created_at`

## 音乐客户端集成要点

1. **先完成鉴权**：注册/登录 → 持久化 Access + Refresh → Access 过期前 refresh；登出时调用 logout。
2. **按大小选上传路径**：封面/歌词走 `POST /v1/files`；音轨走分片三步（initiate → PUT parts → complete）。
3. **播放/下载不走用户 JWT**：先 `access-token`，再对 `/content` 发 Range 请求实现 seek。
4. **所有权隔离**：所有文件操作校验 `owner_id`；跨用户访问一律 `403`。
5. **错误码对齐**：集成时按 `error.code` 分支处理（`FILE_TOO_LARGE`、`FILE_FORBIDDEN`、`RANGE_NOT_SATISFIABLE` 等）。

## 参考

- OpenAPI 原型：`server/docs/prototype/api-contract.openapi.yaml`
- 常量定义：`server/internal/files/errors.go`（10 MB 阈值、8 MB 默认分片、5 MB 最小分片）
- JWT TTL：`server/internal/jwt/manager.go`
- 集成测试：`server/test/integration/auth_flow_test.go`、`file_flow_test.go`、`file_download_test.go`
