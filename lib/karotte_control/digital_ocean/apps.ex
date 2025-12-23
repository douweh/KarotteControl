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

  @doc """
  Creates a new app with the given spec.
  """
  def create(spec) do
    case Client.post("/apps", %{"spec" => spec}) do
      {:ok, %{"app" => app}} -> {:ok, app}
      error -> error
    end
  end

  @doc """
  Lists available instance sizes for App Platform.
  """
  def list_instance_sizes do
    case Client.get("/apps/tiers/instance_sizes") do
      {:ok, %{"instance_sizes" => sizes}} -> {:ok, sizes}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Lists available regions for App Platform.
  """
  def list_regions do
    case Client.get("/apps/regions") do
      {:ok, %{"regions" => regions}} -> {:ok, regions}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Updates an app's spec.
  """
  def update(app_id, spec) do
    case Client.put("/apps/#{app_id}", %{"spec" => spec}) do
      {:ok, %{"app" => app}} -> {:ok, app}
      error -> error
    end
  end
end
