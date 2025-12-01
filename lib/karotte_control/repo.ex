defmodule KarotteControl.Repo do
  use Ecto.Repo,
    otp_app: :karotte_control,
    adapter: Ecto.Adapters.Postgres
end
