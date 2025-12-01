defmodule KarotteControl.DigitalOcean.Databases do
  @moduledoc """
  DigitalOcean Managed Databases API client.
  """

  alias KarotteControl.DigitalOcean.Client

  def list do
    case Client.get("/databases") do
      {:ok, %{"databases" => databases}} -> {:ok, databases}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def get(database_id) do
    case Client.get("/databases/#{database_id}") do
      {:ok, %{"database" => database}} -> {:ok, database}
      error -> error
    end
  end

  def list_dbs(cluster_id) do
    case Client.get("/databases/#{cluster_id}/dbs") do
      {:ok, %{"dbs" => dbs}} -> {:ok, dbs}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def list_users(cluster_id) do
    case Client.get("/databases/#{cluster_id}/users") do
      {:ok, %{"users" => users}} -> {:ok, users}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def list_pools(cluster_id) do
    case Client.get("/databases/#{cluster_id}/pools") do
      {:ok, %{"pools" => pools}} -> {:ok, pools}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end
end
