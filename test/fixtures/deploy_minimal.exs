import Config

config :alcaide,
  app: :minimal_app,
  server: [
    host: "10.0.0.1"
  ],
  app_jail: [
    base_path: "/jails",
    freebsd_version: "14.2-RELEASE"
  ]
