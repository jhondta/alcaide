import Config

config :alcaide,
  app: :test_app,
  server: [
    host: "192.168.1.1",
    user: "deploy",
    port: 22
  ],
  domain: "testapp.com",
  app_jail: [
    base_path: "/jails",
    freebsd_version: "14.1-RELEASE",
    port: 4000
  ],
  accessories: [
    db: [
      type: :postgresql,
      version: "16",
      volume: "/data/postgres:/var/db/postgresql",
      port: 5432
    ]
  ],
  env: [
    DATABASE_URL: "ecto://app:app@10.0.0.4/test_app_prod",
    PHX_HOST: "testapp.com",
    PORT: "4000"
  ]
