# rgw_exporter

A Prometheus exporter for the Ceph RADOS Gateway (RGW). It reads the RGW
[Admin Ops API](https://docs.ceph.com/en/latest/radosgw/adminops/) and exports
metrics for:

- **Usage log**: ops, successful ops, bytes sent and received, per bucket, owner and category
- **Buckets**: size, utilized size, object count, shards, bucket quota, and optional bucket tags as labels
- **Users**: metadata, suspension, stats, user quota and per-bucket quota
- **Accounts** (Squid 19.x / Tentacle 20.x and later): metadata, account quota
  and bucket quota, resource limits, and user, bucket, object and byte totals
  per account

## How accounts are handled

Since Squid, an RGW **account** groups users together. A bucket created by an
account user is owned by the **account ID** (for example `RGW12345678901234567`),
not by the user. The exporter:

1. lists all users (with pagination) and reads each one's `account_id`,
2. finds account IDs from `GET /admin/metadata/account`, from users' `account_id`,
   and from bucket owners,
3. reads each account with `GET /admin/account?id=<id>`,
4. adds an `account` label to usage, bucket and user metrics, and adds up
   bucket stats per account.

Account info is optional. Without the `metadata=read` or `accounts=read` cap,
the exporter still finds accounts from users and bucket owners and still exports
their total usage.

## Requirements

- Ceph RGW with the Admin Ops API enabled (Tentacle, Squid, Reef and older all work;
  account metrics need Squid or later)
- To get usage-log metrics, turn on the usage log:

  ```sh
  ceph config set client.rgw rgw_enable_usage_log true
  ```

- A regular RGW user (**not** an account user) with read-only admin caps:

  ```sh
  radosgw-admin user create --uid=rgw-exporter --display-name="RGW exporter" \
    --caps="buckets=read;users=read;usage=read;metadata=read;accounts=read"
  ```

  To add caps to an existing user:

  ```sh
  radosgw-admin caps add --uid=rgw-exporter \
    --caps="buckets=read;users=read;usage=read;metadata=read;accounts=read"
  ```

## Running

### Docker

```sh
docker build -t rgw_exporter .
docker run -d -p 9242:9242 \
  -e RADOSGW_SERVER=http://rgw.example.com:8080 \
  -e ACCESS_KEY=... -e SECRET_KEY=... \
  -e SIGNATURE=v2 \
  -e STORE=my-cluster \
  rgw_exporter
```

or pull image

```
docker pull docker.io/quangvv17/rgw_exporter:v1.0.0
```

### Python

```sh
pip install -r requirements.txt
./rgw_exporter.py -H http://rgw.example.com:8080 -a ACCESS_KEY -s SECRET_KEY -S my-cluster
```



Metrics are served at `http://<host>:9242/metrics`.

### Prometheus

```yaml
scrape_configs:
  - job_name: rgw
    scrape_interval: 60s
    static_configs:
      - targets: ["rgw-exporter:9242"]
```

## Large clusters (thousands of users)

The Admin Ops API has no bulk "user info" call. The exporter must make one
`GET /admin/user?uid=…&stats=True` request per user, so a full collection
takes longer as the number of users grows. The exporter is built for this:

- **Background collection**: by default (`INTERVAL=60`), a background thread
  queries RGW every 60 seconds and `/metrics` serves the last result
  straight away. Prometheus scrapes no longer time out, however many users
  there are. Set `INTERVAL` to at least how long one collection takes. That
  time is logged (`Collected N users … in Xs`) and exported as
  `radosgw_usage_scrape_duration_seconds`.
- **Pagination**: RGW returns at most 1000 keys per listing page. User,
  metadata-user and account listings follow the `marker` until the list is no
  longer `truncated`. They stop safely if a release returns a marker that
  doesn't move forward.
- **Parallel requests**: user and account info are fetched with `THREADS`
  parallel requests (default 10). Raise it (for example to 20–50) to collect
  faster, as long as your RGW can handle the extra load.
- **Retries**: HTTP 429/5xx responses and connection errors are retried
  (`RETRIES`, default 3) with backoff. A few failures in thousands of requests
  won't leave gaps in the data.

For example, with 3,500 users, 20 threads and 5 ms RGW latency, one
collection takes about 5 seconds.

To check that a collection is complete and up to date:

```promql
# Users collected in the last run (compare with `radosgw-admin user list | jq length`)
radosgw_usage_users_collected

# Alert if data is older than 5 minutes
time() - radosgw_usage_scrape_timestamp_seconds > 300
```

Set `INTERVAL=0` to query RGW on every scrape instead, as older versions did.
This only works for small clusters, and `scrape_timeout` must be longer than
one collection.

## Configuration

Each option can be set with a flag or an environment variable.

| Flag | Env | Default | Description |
|---|---|---|---|
| `-H`, `--host` | `RADOSGW_SERVER` | `http://radosgw:80` | RGW endpoint |
| `-e`, `--admin-entry` | `ADMIN_ENTRY` | `admin` | Admin API entry point (`rgw_admin_entry`) |
| `-a`, `--access-key` | `ACCESS_KEY` | `NA` | S3 access key |
| `-s`, `--secret-key` | `SECRET_KEY` | `NA` | S3 secret key |
| `-k`, `--insecure` | `INSECURE` | `false` | Skip TLS certificate verification |
| `-p`, `--port` | `VIRTUAL_PORT` | `9242` | Listen port |
| `-S`, `--store` | `STORE` | `us-east-1` | Value of the `store` label |
| `-t`, `--timeout` | `TIMEOUT` | `60` | Timeout for each request, in seconds |
| `-l`, `--log-level` | `LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL` |
| `-T`, `--tag-list` | `TAG_LIST` | _(empty)_ | Comma-separated bucket tags to export as `tag_<name>` labels |
| `--signature` | `SIGNATURE` | `v4` | AWS signature version: `v4` or `v2` |
| `--region` | `REGION` | `us-east-1` | Region used in the SigV4 credential scope |
| `--threads` | `THREADS` | `10` | Number of parallel user and account info requests |
| `-c`, `--collectors` | `COLLECTORS` | `usage,buckets,users,accounts` | Collectors to turn on |
| `-i`, `--interval` | `INTERVAL` | `60` | Seconds between background collections; `0` queries RGW on every scrape |
| `--retries` | `RETRIES` | `3` | Retries for failed admin API requests (429/5xx, connection errors) |

If the usage log is off, use `COLLECTORS=buckets,users,accounts` so that each
scrape doesn't log a request error.

## Metrics

All metrics have a `store` label.

### Usage log (counters)

Labels: `bucket`, `owner`, `account`, `category`

| Metric | Description |
|---|---|
| `radosgw_usage_ops_total` | Number of operations |
| `radosgw_usage_successful_ops_total` | Number of successful operations |
| `radosgw_usage_sent_bytes_total` | Bytes sent by RGW |
| `radosgw_usage_received_bytes_total` | Bytes received by RGW |

### Buckets

Labels: `bucket`, `owner`, `account`, `tenant`, `zonegroup`, and one `tag_<name>` per entry in `TAG_LIST`

| Metric | Description |
|---|---|
| `radosgw_usage_bucket_bytes` | Used bytes (`size_actual`) |
| `radosgw_usage_bucket_utilized_bytes` | Utilized bytes (after compression) |
| `radosgw_usage_bucket_objects` | Number of objects |
| `radosgw_usage_bucket_shards` | Number of index shards |
| `radosgw_usage_bucket_quota_enabled` | Bucket quota enabled |
| `radosgw_usage_bucket_quota_size` | Quota max size (`-1` = unlimited) |
| `radosgw_usage_bucket_quota_size_bytes` | Quota max size in bytes |
| `radosgw_usage_bucket_quota_size_objects` | Quota max objects (`-1` = unlimited) |

### Users

Labels: `user`, `account`

| Metric | Description |
|---|---|
| `radosgw_user_metadata` | Always `1`. Also has `display_name`, `email`, `storage_class` and `type` labels (`type` is `root` for an account root user) |
| `radosgw_usage_user_suspended` | User is suspended |
| `radosgw_usage_user_total_bytes` | Bytes owned by the user |
| `radosgw_usage_user_total_objects` | Objects owned by the user |
| `radosgw_usage_user_quota_enabled` / `_size` / `_size_bytes` / `_size_objects` | User quota |
| `radosgw_usage_user_bucket_quota_enabled` / `_size` / `_size_bytes` / `_size_objects` | Per-bucket quota for the user |

> Buckets created by account users are owned by the account, so these users
> usually report `0` for user totals. Use the account metrics for them.

### Accounts (Squid+)

Labels: `account`

| Metric | Description |
|---|---|
| `radosgw_account_metadata` | Always `1`. Also has `name`, `email` and `tenant` labels |
| `radosgw_usage_account_users` | Number of users in the account |
| `radosgw_usage_account_buckets` | Number of buckets owned by the account |
| `radosgw_usage_account_total_bytes` | Bytes in the account's buckets |
| `radosgw_usage_account_total_utilized_bytes` | Utilized bytes in the account's buckets |
| `radosgw_usage_account_total_objects` | Objects in the account's buckets |
| `radosgw_usage_account_quota_enabled` / `_size` / `_size_bytes` / `_size_objects` | Account quota |
| `radosgw_usage_account_bucket_quota_enabled` / `_size` / `_size_bytes` / `_size_objects` | Per-bucket quota for the account |
| `radosgw_usage_account_max_users` / `_max_roles` / `_max_groups` / `_max_buckets` / `_max_access_keys` | Account resource limits |

### Exporter

| Metric | Description |
|---|---|
| `radosgw_usage_up` | `1` if the bucket API could be queried |
| `radosgw_usage_scrape_errors` | Number of failed admin API requests in the last scrape |
| `radosgw_usage_scrape_duration_seconds` | How long the last scrape took |
| `radosgw_usage_scrape_timestamp_seconds` | Unix time when the last collection from RGW finished |
| `radosgw_usage_users_collected` | Number of users whose info was collected in the last scrape |

### Example queries

```promql
# Storage used per account
sum by (account) (radosgw_usage_account_total_bytes)

# Account quota usage ratio (only accounts with a size quota)
radosgw_usage_account_total_bytes
  / (radosgw_usage_account_quota_size_bytes > 0)

# Top 10 buckets by size, with the account name
topk(10, radosgw_usage_bucket_bytes)
  * on (account) group_left(name) radosgw_account_metadata
```