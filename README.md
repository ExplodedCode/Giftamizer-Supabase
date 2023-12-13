# Supabase Docker

| Docker Image           | Description                                             | Ports      |
| ---------------------- | ------------------------------------------------------- | ---------- |
| supabase/studio        | Supabase Admin Portal                                   | 3000       |
| supabase/gotrue        | Supabase User Auth                                      |            |
| supabase/realtime      | Supabase Realtime listener                              |            |
| supabase/deno-relay    | Relay function requests to another server with JWT Auth |            |
| supabase/storage-api   | Supabase Bucket Handler                                 |            |
| darthsim/imgproxy      | Resize and Convert Remote Images                        |            |
| supabase/postgres      | Unmodified Postgres with some useful plugins            | 5432       |
| supabase/postgres-meta | RESTful API for managing your Postgres                  |            |
| postgrest/postgrest    | RESTful API from any existing PostgreSQL database       |            |
| evantrow/smtp2graph    | Relay email from SMTP to the Microsoft Graph            | 8080       |
| kong                   | API Gateway for APIs and Microservices                  | 8000, 8443 |

## Start Docker Stack

```bash
docker compose up -d
```
