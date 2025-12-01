defmodule KarotteControlWeb.UserSessionHTML do
  use KarotteControlWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:karotte_control, KarotteControl.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
