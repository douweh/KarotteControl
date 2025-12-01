defmodule KarotteControl.DigitalOcean.Apps do
  @moduledoc """
  DigitalOcean App Platform API client.
  """

  alias KarotteControl.DigitalOcean.Client

  def list do
    case Client.get("/apps") do
      {:ok, %{"apps" => apps}} -> {:ok, apps}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def get(app_id) do
    case Client.get("/apps/#{app_id}") do
      {:ok, %{"app" => app}} -> {:ok, app}
      error -> error
    end
  end

  def list_deployments(app_id) do
    case Client.get("/apps/#{app_id}/deployments") do
      {:ok, %{"deployments" => deployments}} -> {:ok, deployments}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end
end
