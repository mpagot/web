defmodule Trento.Domain.SapSystem do
  @moduledoc """
  The SAP system aggregate manages all the domain logic related to
  deployed SAP systems, which are composed by a database and application layers.
  **The HANA database is the only supported database type.**

  In order to have a fully registered SAP system, both the database and application
  composing this system must be registered. And each of the two layers might be composed
  by multiple instances altogether. This means that a SAP system aggregate state can have
  multiple application/database instances.

  ## SAP instance

  A SAP instance can be seen as a single SAP workload installation running in a
  particular host. So the instance runs entirely in one host, but on the other hand
  multiple different SAP instances might be running in the same host.

  For example, a HANA database might be composed by two database instances
  that are working together in a System Replication scenario.

  ## SAP system registration process

  The SAP system registration process has some caveats, so let's see them in more details.

  As a main concept, the SAP system is uniquely identified by the database ID. This means that
  there cannot exist any SAP system without a database, so Trento agents must be running
  in those hosts in order to start the registration.

  That being said, this is the logical order of events in order to register a full system:

  1. A SAP system discovery message with a new database instance is received. At this point, the
     registration process starts and the database is registered.
     Any application instance discovery message without an associated database is ignored.
  2. New database instances/updates coming from already registered database instances are registered/applied.
  3. A SAP system discovery with a new application instance is received, and the database associated to
     this application exists, the application instance is registered together with the complete
     SAP system. The SAP system is fully registered now.
  4. New application instances/updates coming from already registered application instances are registered/applied.

  Find additional information about the application/database association in `Trento.Domain.Commands.RegisterApplicationInstance`.
  """

  require Trento.Domain.Enums.Health, as: Health

  alias Commanded.Aggregate.Multi

  alias Trento.Domain.SapSystem

  alias Trento.Domain.SapSystem.{
    Application,
    Database,
    Instance
  }

  alias Trento.Domain.Commands.{
    RegisterApplicationInstance,
    RegisterDatabaseInstance
  }

  alias Trento.Domain.Events.{
    ApplicationInstanceHealthChanged,
    ApplicationInstanceRegistered,
    DatabaseHealthChanged,
    DatabaseInstanceHealthChanged,
    DatabaseInstanceRegistered,
    DatabaseInstanceSystemReplicationChanged,
    DatabaseRegistered,
    SapSystemHealthChanged,
    SapSystemRegistered
  }

  alias Trento.Domain.HealthService

  @required_fields []

  use Trento.Type

  deftype do
    field :sap_system_id, Ecto.UUID
    field :sid, :string
    field :health, Ecto.Enum, values: Health.values()

    embeds_one :database, Database
    embeds_one :application, Application
  end

  # First time that a Database instance is registered, the SAP System starts its registration process.
  # When an Application is discovered, the SAP System completes the registration process.
  def execute(
        %SapSystem{sap_system_id: nil},
        %RegisterDatabaseInstance{
          sap_system_id: sap_system_id,
          sid: sid,
          tenant: tenant,
          host_id: host_id,
          instance_number: instance_number,
          instance_hostname: instance_hostname,
          features: features,
          http_port: http_port,
          https_port: https_port,
          start_priority: start_priority,
          system_replication: system_replication,
          system_replication_status: system_replication_status,
          health: health
        }
      ) do
    [
      %DatabaseRegistered{
        sap_system_id: sap_system_id,
        sid: sid,
        health: health
      },
      %DatabaseInstanceRegistered{
        sap_system_id: sap_system_id,
        sid: sid,
        tenant: tenant,
        instance_number: instance_number,
        instance_hostname: instance_hostname,
        features: features,
        http_port: http_port,
        https_port: https_port,
        start_priority: start_priority,
        host_id: host_id,
        system_replication: system_replication,
        system_replication_status: system_replication_status,
        health: health
      }
    ]
  end

  # When a RegisterDatabaseInstance command is received by an existing SAP System aggregate,
  # the SAP System aggregate registers the Database instance if it is not already registered
  # and updates the health when needed.
  def execute(
        %SapSystem{database: %Database{instances: instances}} = sap_system,
        %RegisterDatabaseInstance{host_id: host_id, instance_number: instance_number} = command
      ) do
    instance = get_instance(instances, host_id, instance_number)

    sap_system
    |> Multi.new()
    |> Multi.execute(fn _ ->
      maybe_emit_database_instance_system_replication_changed_event(instance, command)
    end)
    |> Multi.execute(fn _ ->
      maybe_emit_database_instance_health_changed_event(instance, command)
    end)
    |> Multi.execute(fn _ ->
      maybe_emit_database_instance_registered_event(instance, command)
    end)
    |> Multi.execute(&maybe_emit_database_health_changed_event/1)
    |> Multi.execute(&maybe_emit_sap_system_health_changed_event/1)
  end

  # When an Application is discovered, the SAP System completes the registration process.
  def execute(
        %SapSystem{application: nil},
        %RegisterApplicationInstance{
          sap_system_id: sap_system_id,
          sid: sid,
          instance_number: instance_number,
          instance_hostname: instance_hostname,
          tenant: tenant,
          db_host: db_host,
          features: features,
          http_port: http_port,
          https_port: https_port,
          start_priority: start_priority,
          host_id: host_id,
          health: health
        }
      ) do
    [
      %SapSystemRegistered{
        sap_system_id: sap_system_id,
        sid: sid,
        tenant: tenant,
        db_host: db_host,
        health: health
      },
      %ApplicationInstanceRegistered{
        sap_system_id: sap_system_id,
        sid: sid,
        instance_number: instance_number,
        instance_hostname: instance_hostname,
        features: features,
        http_port: http_port,
        https_port: https_port,
        start_priority: start_priority,
        host_id: host_id,
        health: health
      }
    ]
  end

  # When a RegisterApplicationInstance command is received by an existing SAP System aggregate,
  # the SAP System aggregate registers the Application instance if it is not already registered
  # and updates the health when needed.
  def execute(
        %SapSystem{application: %Application{instances: instances}} = sap_system,
        %RegisterApplicationInstance{
          sap_system_id: sap_system_id,
          sid: sid,
          instance_number: instance_number,
          instance_hostname: instance_hostname,
          features: features,
          http_port: http_port,
          https_port: https_port,
          start_priority: start_priority,
          host_id: host_id,
          health: health
        }
      ) do
    instance =
      Enum.find(instances, fn
        %Instance{host_id: ^host_id, instance_number: ^instance_number} ->
          true

        _ ->
          false
      end)

    event =
      case instance do
        %Instance{health: ^health} ->
          nil

        %Instance{host_id: host_id, instance_number: instance_number} ->
          %ApplicationInstanceHealthChanged{
            sap_system_id: sap_system_id,
            host_id: host_id,
            instance_number: instance_number,
            health: health
          }

        nil ->
          %ApplicationInstanceRegistered{
            sap_system_id: sap_system_id,
            sid: sid,
            instance_number: instance_number,
            instance_hostname: instance_hostname,
            features: features,
            http_port: http_port,
            https_port: https_port,
            start_priority: start_priority,
            host_id: host_id,
            health: health
          }
      end

    sap_system
    |> Multi.new()
    |> Multi.execute(fn _ -> event end)
    |> Multi.execute(&maybe_emit_sap_system_health_changed_event/1)
  end

  def apply(
        %SapSystem{sap_system_id: nil},
        %DatabaseRegistered{
          sap_system_id: sap_system_id,
          sid: sid,
          health: health
        }
      ) do
    %SapSystem{
      sap_system_id: sap_system_id,
      database: %Database{
        sid: sid,
        health: health
      }
    }
  end

  def apply(
        %SapSystem{database: %Database{instances: instances} = database} = sap_system,
        %DatabaseInstanceRegistered{
          sid: sid,
          system_replication: system_replication,
          system_replication_status: system_replication_status,
          instance_number: instance_number,
          features: features,
          host_id: host_id,
          health: health
        }
      ) do
    instances = [
      %Instance{
        sid: sid,
        system_replication: system_replication,
        system_replication_status: system_replication_status,
        instance_number: instance_number,
        features: features,
        host_id: host_id,
        health: health
      }
      | instances
    ]

    %SapSystem{
      sap_system
      | database: Map.put(database, :instances, instances)
    }
  end

  def apply(
        %SapSystem{database: %Database{instances: instances} = database} = sap_system,
        %DatabaseInstanceSystemReplicationChanged{
          host_id: host_id,
          instance_number: instance_number,
          system_replication: system_replication,
          system_replication_status: system_replication_status
        }
      ) do
    instances =
      Enum.map(
        instances,
        fn
          %Instance{host_id: ^host_id, instance_number: ^instance_number} = instance ->
            %Instance{
              instance
              | system_replication: system_replication,
                system_replication_status: system_replication_status
            }

          instance ->
            instance
        end
      )

    %SapSystem{sap_system | database: Map.put(database, :instances, instances)}
  end

  def apply(
        %SapSystem{database: %Database{instances: instances} = database} = sap_system,
        %DatabaseInstanceHealthChanged{
          host_id: host_id,
          instance_number: instance_number,
          health: health
        }
      ) do
    instances =
      Enum.map(
        instances,
        fn
          %Instance{host_id: ^host_id, instance_number: ^instance_number} = instance ->
            %Instance{instance | health: health}

          instance ->
            instance
        end
      )

    %SapSystem{sap_system | database: Map.put(database, :instances, instances)}
  end

  def apply(
        %SapSystem{application: nil} = sap_system,
        %ApplicationInstanceRegistered{
          sid: sid,
          instance_number: instance_number,
          features: features,
          host_id: host_id,
          health: health
        }
      ) do
    application = %Application{
      sid: sid,
      instances: [
        %Instance{
          sid: sid,
          instance_number: instance_number,
          features: features,
          host_id: host_id,
          health: health
        }
      ]
    }

    %SapSystem{
      sap_system
      | application: application
    }
  end

  def apply(
        %SapSystem{application: %Application{instances: instances} = application} = sap_system,
        %ApplicationInstanceRegistered{
          sid: sid,
          instance_number: instance_number,
          features: features,
          host_id: host_id,
          health: health
        }
      ) do
    instances = [
      %Instance{
        sid: sid,
        instance_number: instance_number,
        features: features,
        host_id: host_id,
        health: health
      }
      | instances
    ]

    %SapSystem{
      sap_system
      | application: Map.put(application, :instances, instances)
    }
  end

  def apply(
        %SapSystem{application: %Application{instances: instances} = application} = sap_system,
        %ApplicationInstanceHealthChanged{
          host_id: host_id,
          instance_number: instance_number,
          health: health
        }
      ) do
    instances =
      Enum.map(
        instances,
        fn
          %Instance{host_id: ^host_id, instance_number: ^instance_number} = instance ->
            %Instance{instance | health: health}

          instance ->
            instance
        end
      )

    %SapSystem{sap_system | application: Map.put(application, :instances, instances)}
  end

  def apply(%SapSystem{} = sap_system, %SapSystemRegistered{sid: sid, health: health}) do
    %SapSystem{
      sap_system
      | sid: sid,
        health: health
    }
  end

  def apply(%SapSystem{} = sap_system, %SapSystemHealthChanged{health: health}) do
    %SapSystem{
      sap_system
      | health: health
    }
  end

  def apply(%SapSystem{database: %Database{} = database} = sap_system, %DatabaseHealthChanged{
        health: health
      }) do
    %SapSystem{
      sap_system
      | database: Map.put(database, :health, health)
    }
  end

  defp maybe_emit_database_instance_system_replication_changed_event(
         %Instance{
           system_replication: system_replication,
           system_replication_status: system_replication_status
         },
         %RegisterDatabaseInstance{
           sap_system_id: sap_system_id,
           host_id: host_id,
           instance_number: instance_number,
           system_replication: new_system_replication,
           system_replication_status: new_system_replication_status
         }
       )
       when system_replication != new_system_replication or
              system_replication_status != new_system_replication_status do
    %DatabaseInstanceSystemReplicationChanged{
      sap_system_id: sap_system_id,
      host_id: host_id,
      instance_number: instance_number,
      system_replication: new_system_replication,
      system_replication_status: new_system_replication_status
    }
  end

  defp maybe_emit_database_instance_system_replication_changed_event(_, _), do: nil

  defp maybe_emit_database_instance_health_changed_event(
         %Instance{
           health: health
         },
         %RegisterDatabaseInstance{
           sap_system_id: sap_system_id,
           host_id: host_id,
           instance_number: instance_number,
           health: new_health
         }
       )
       when health != new_health do
    %DatabaseInstanceHealthChanged{
      sap_system_id: sap_system_id,
      host_id: host_id,
      instance_number: instance_number,
      health: new_health
    }
  end

  defp maybe_emit_database_instance_health_changed_event(_, _), do: nil

  defp maybe_emit_database_instance_registered_event(
         nil,
         %RegisterDatabaseInstance{
           sap_system_id: sap_system_id,
           sid: sid,
           tenant: tenant,
           instance_number: instance_number,
           instance_hostname: instance_hostname,
           features: features,
           http_port: http_port,
           https_port: https_port,
           start_priority: start_priority,
           host_id: host_id,
           system_replication: system_replication,
           system_replication_status: system_replication_status,
           health: health
         }
       ) do
    %DatabaseInstanceRegistered{
      sap_system_id: sap_system_id,
      sid: sid,
      tenant: tenant,
      instance_number: instance_number,
      instance_hostname: instance_hostname,
      features: features,
      http_port: http_port,
      https_port: https_port,
      start_priority: start_priority,
      host_id: host_id,
      system_replication: system_replication,
      system_replication_status: system_replication_status,
      health: health
    }
  end

  defp maybe_emit_database_instance_registered_event(_, _), do: nil

  # Returns a DatabaseHealthChanged event if the newly computed aggregated health of all the instances
  # is different from the previous Database health.
  defp maybe_emit_database_health_changed_event(%SapSystem{
         sap_system_id: sap_system_id,
         database: %Database{instances: instances, health: health}
       }) do
    new_health =
      instances
      |> Enum.map(& &1.health)
      |> HealthService.compute_aggregated_health()

    if new_health != health do
      %DatabaseHealthChanged{
        sap_system_id: sap_system_id,
        health: new_health
      }
    end
  end

  # Do not emit health changed event as the SAP system is not completely registered yet
  defp maybe_emit_sap_system_health_changed_event(%SapSystem{application: nil}), do: nil

  # Returns a SapSystemHealthChanged event when the aggregated health of the application instances
  # and database is different from the previous SAP system health.
  defp maybe_emit_sap_system_health_changed_event(%SapSystem{
         sap_system_id: sap_system_id,
         health: health,
         application: %Application{instances: instances},
         database: %Database{health: database_health}
       }) do
    new_health =
      instances
      |> Enum.map(& &1.health)
      |> Kernel.++([database_health])
      |> HealthService.compute_aggregated_health()

    if new_health != health do
      %SapSystemHealthChanged{
        sap_system_id: sap_system_id,
        health: new_health
      }
    end
  end

  defp get_instance(instances, host_id, instance_number) do
    Enum.find(instances, fn
      %Instance{host_id: ^host_id, instance_number: ^instance_number} ->
        true

      _ ->
        false
    end)
  end
end
