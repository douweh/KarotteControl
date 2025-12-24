defmodule KarotteControl.Repo.Migrations.CreateDokkuAppDeployments do
  use Ecto.Migration

  def change do
    create table(:dokku_app_deployments) do
      add :droplet_id, :string, null: false
      add :app_name, :string, null: false

      # Registry image source
      add :registry_name, :string
      add :repository_name, :string
      add :tag, :string, default: "latest"

      # Last known digest for auto-deploy detection
      add :last_digest, :string

      # Auto-deploy settings
      add :auto_deploy, :boolean, default: false

      # Post-deploy command (e.g., migrations)
      add :post_deploy_command, :string

      # Last deployment info
      add :last_deployed_at, :utc_datetime
      add :last_deploy_status, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dokku_app_deployments, [:droplet_id, :app_name])
    create index(:dokku_app_deployments, [:auto_deploy])
  end
end
