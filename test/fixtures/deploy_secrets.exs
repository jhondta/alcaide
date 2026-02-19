import Config

config :alcaide,
  env: [
    SECRET_KEY_BASE: "test-secret-key-base-value",
    DATABASE_URL: "ecto://secret_user:secret_pass@10.0.0.4/my_app_prod"
  ]
