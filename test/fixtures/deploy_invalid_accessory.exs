import Config

config :alcaide,
  app: :bad_app,
  server: [
    host: "192.168.1.1"
  ],
  app_jail: [
    base_path: "/jails",
    freebsd_version: "14.1-RELEASE"
  ],
  accessories: [
    db: [
      type: :postgresql
      # Missing: version, volume
    ]
  ]
