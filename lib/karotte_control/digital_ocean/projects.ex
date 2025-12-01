defmodule KarotteControl.DigitalOcean.Projects do
  @moduledoc """
  DigitalOcean Projects API client.
  """

  alias KarotteControl.DigitalOcean.Client

  def list do
    case Client.get("/projects") do
      {:ok, %{"projects" => projects}} -> {:ok, projects}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def get(project_id) do
    case Client.get("/projects/#{project_id}") do
      {:ok, %{"project" => project}} -> {:ok, project}
      error -> error
    end
  end

  def list_resources(project_id) do
    case Client.get("/projects/#{project_id}/resources") do
      {:ok, %{"resources" => resources}} -> {:ok, resources}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Extracts resource URNs from project resources by type.
  Resource URNs look like: "do:app:abc123", "do:database:xyz456", etc.
  """
  def extract_urns_by_type(resources, type) do
    resources
    |> Enum.filter(fn r -> String.starts_with?(r["urn"], "do:#{type}:") end)
    |> Enum.map(fn r -> r["urn"] end)
  end

  @doc """
  Extracts the ID from a URN like "do:app:abc123" -> "abc123"
  """
  def extract_id_from_urn(urn) do
    urn
    |> String.split(":")
    |> List.last()
  end

  @doc """
  Assigns resources to a project by their URNs.
  """
  def assign_resources(project_id, urns) when is_list(urns) do
    resources = Enum.map(urns, fn urn -> %{"urn" => urn} end)

    Client.post("/projects/#{project_id}/resources", %{"resources" => resources})
  end
end
