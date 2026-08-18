shared_utils = import_module("../../shared_utils/shared_utils.star")
input_parser = import_module("../../package_io/input_parser.star")
cl_context = import_module("../../cl/cl_context.star")
cl_node_ready_conditions = import_module("../../cl/cl_node_ready_conditions.star")
cl_shared = import_module("../cl_shared.star")
node_metrics = import_module("../../node_metrics_info.star")
constants = import_module("../../package_io/constants.star")

REAM_ENTRYPOINT_COMMAND = "ream"

BEACON_DATA_DIRPATH_ON_SERVICE_CONTAINER = "/data/ream/beacon-data"

BEACON_HTTP_PORT_NUM = 5052 
BEACON_SOCKET_PORT_NUM = 9000 
BEACON_DISCOVERY_PORT_NUM = 9000
BEACON_METRICS_PORT_NUM = 8008
BEACON_METRICS_PATH = "/metrics"

ENTRYPOINT_ARGS = ["sh", "-c"]

# `ream --verbosity` takes a number from 1 (error) to 5 (trace), not a level name.
VERBOSITY_LEVELS = {
    constants.GLOBAL_LOG_LEVEL.error: "1",
    constants.GLOBAL_LOG_LEVEL.warn: "2",
    constants.GLOBAL_LOG_LEVEL.info: "3",
    constants.GLOBAL_LOG_LEVEL.debug: "4",
    constants.GLOBAL_LOG_LEVEL.trace: "5",
}

def launch(
    plan,
    launcher,
    beacon_service_name,
    participant,
    global_log_level,
    bootnode_contexts,
    el_context,
    full_name,
    node_keystore_files,
    snooper_el_engine_context,
    persistent,
    tolerations,
    node_selectors,
    checkpoint_sync_enabled,
    checkpoint_sync_url,
    port_publisher,
    participant_index,
    network_params,
    extra_files_artifacts,
    backend,
    tempo_otlp_grpc_url=None,
    otel_otlp_grpc_url=None,
    bootnode_enr_override=None,
    cl_binary_artifact=None,
):
    config = get_beacon_config(
        plan,
        launcher,
        beacon_service_name,
        participant,
        global_log_level,
        bootnode_contexts,
        el_context,
        full_name,
        node_keystore_files,
        snooper_el_engine_context,
        persistent,
        tolerations,
        node_selectors,
        checkpoint_sync_enabled,
        checkpoint_sync_url,
        port_publisher,
        participant_index,
        network_params,
        extra_files_artifacts,
        backend,
        tempo_otlp_grpc_url,
        otel_otlp_grpc_url,
        bootnode_enr_override,
        cl_binary_artifact,
    )
    beacon_service = plan.add_service(beacon_service_name, config)
    cl_context_obj = get_cl_context(
        plan,
        beacon_service_name,
        beacon_service,
        participant,
        snooper_el_engine_context,
        node_keystore_files,
        node_selectors,
    )
    return cl_context_obj

def get_beacon_config(
    plan,
    launcher,
    beacon_service_name,
    participant,
    global_log_level,
    bootnode_contexts,
    el_context,
    full_name,
    node_keystore_files,
    snooper_el_engine_context,
    persistent,
    tolerations,
    node_selectors,
    checkpoint_sync_enabled,
    checkpoint_sync_url,
    port_publisher,
    participant_index,
    network_params,
    extra_files_artifacts,
    backend,
    tempo_otlp_grpc_url,
    otel_otlp_grpc_url=None,
    bootnode_enr_override=None,
    cl_binary_artifact=None,
):
    log_level = input_parser.get_client_log_level_or_default(
        participant.cl_log_level, global_log_level, VERBOSITY_LEVELS
    )

    EXECUTION_ENGINE_ENDPOINT = None
    if el_context != None:
        if participant.snooper_enabled:
            EXECUTION_ENGINE_ENDPOINT = "http://{0}:{1}".format(
                snooper_el_engine_context.ip_addr,
                snooper_el_engine_context.engine_rpc_port_num,
            )
        else:
            EXECUTION_ENGINE_ENDPOINT = "http://{0}:{1}".format(
                el_context.dns_name,
                el_context.engine_rpc_port_num,
            )

    public_ports = {}
    public_ports_for_component = None
    if port_publisher.cl_enabled:
        public_ports_for_component = shared_utils.get_public_ports_for_component(
            "cl", port_publisher, participant_index
        )
        public_ports = cl_shared.get_general_cl_public_port_specs(
            public_ports_for_component
        )

    discovery_port_tcp = (
        public_ports_for_component[0]
        if public_ports_for_component
        else BEACON_SOCKET_PORT_NUM
    )
    discovery_port_udp = (
        public_ports_for_component[0]
        if public_ports_for_component
        else BEACON_DISCOVERY_PORT_NUM
    )

    used_port_assignments = {
        constants.TCP_DISCOVERY_PORT_ID: discovery_port_tcp,
        constants.UDP_DISCOVERY_PORT_ID: discovery_port_udp,
        constants.HTTP_PORT_ID: BEACON_HTTP_PORT_NUM,
        constants.METRICS_PORT_ID: BEACON_METRICS_PORT_NUM,
    }

    if participant.skip_start:
        used_ports = shared_utils.get_port_specs(used_port_assignments, wait=None)
    else:
        used_ports = shared_utils.get_port_specs(used_port_assignments)

    cmd = [
        REAM_ENTRYPOINT_COMMAND,
        # --verbosity is a global argument, so it has to precede the subcommand.
        "--verbosity={0}".format(log_level),
        "beacon_node",
        "--network="
        + constants.GENESIS_CONFIG_MOUNT_PATH_ON_CONTAINER
        + "/config.yaml",
        "--genesis-state-path="
        + constants.GENESIS_CONFIG_MOUNT_PATH_ON_CONTAINER
        + "/genesis.ssz",
        "--http-address=0.0.0.0",
        "--http-port={0}".format(BEACON_HTTP_PORT_NUM),
        "--http-allow-origin",
        "--socket-address=0.0.0.0",
        "--socket-port={0}".format(discovery_port_tcp),
        "--discovery-port={0}".format(discovery_port_udp),
        "--metrics",
        "--metrics-address=0.0.0.0",
        "--metrics-port={0}".format(BEACON_METRICS_PORT_NUM),
    ]

    if el_context != None:
        cmd.append("--execution-endpoint=" + EXECUTION_ENGINE_ENDPOINT)
        cmd.append(
            "--execution-jwt-secret=" + constants.JWT_MOUNT_PATH_ON_CONTAINER
        )

    if checkpoint_sync_enabled:
        cmd.append("--checkpoint-sync-url=" + checkpoint_sync_url)

    supernode_cmd = []
    if participant.supernode:
        cmd.extend(supernode_cmd)

    bootnode_arg = bootnode_enr_override
    if network_params.network not in constants.PUBLIC_NETWORKS:
        if (
            network_params.network == constants.NETWORK_NAME.kurtosis
            or constants.NETWORK_NAME.shadowfork in network_params.network
        ):
            if bootnode_contexts != None and bootnode_arg == None:
                bootnode_arg = ",".join(
                    [ctx.enr for ctx in bootnode_contexts[: constants.MAX_ENR_ENTRIES]]
                )
        elif bootnode_arg == None: 
            bootnode_arg = shared_utils.get_devnet_enrs_list(
                plan, launcher.el_cl_genesis_data.files_artifact_uuid
            )

    if bootnode_arg != None:
        cmd.append("--bootnodes=" + bootnode_arg)

    if len(participant.cl_extra_params) > 0:
        cmd.extend([param for param in participant.cl_extra_params])

    files = {
        constants.GENESIS_DATA_MOUNTPOINT_ON_CLIENTS: launcher.el_cl_genesis_data.files_artifact_uuid,
    }
    if el_context != None:
        files[constants.JWT_MOUNTPOINT_ON_CLIENTS] = launcher.jwt_file

    processed_mounts = shared_utils.process_extra_mounts(
        plan, participant.cl_extra_mounts, extra_files_artifacts
    )
    for mount_path, artifact in processed_mounts.items():
        files[mount_path] = artifact

    if cl_binary_artifact != None:
        files["/opt/bin"] = cl_binary_artifact.artifact

    cmd_str = " ".join(cmd)
    if cl_binary_artifact != None:
        cmd_str = (
            "cp /opt/bin/{0} /usr/local/bin/ream && exec ".format(
                cl_binary_artifact.filename
            )
            + cmd_str
        )
    else:
        cmd_str = "exec " + cmd_str

    config_args = {
        "image": participant.cl_image,
        "ports": used_ports,
        "public_ports": public_ports,
        "publish_udp": port_publisher.cl_enabled,
        "entrypoint": ["sh", "-c"],
        "cmd": [cmd_str],
        "files": files,
        "env_vars": shared_utils.with_otel_env_vars(
            participant.cl_extra_env_vars,
            otel_otlp_grpc_url,
            beacon_service_name,
        ),
        "private_ip_address_placeholder": constants.PRIVATE_IP_ADDRESS_PLACEHOLDER,
        "labels": shared_utils.label_maker(
            client=constants.CL_TYPE.ream,
            client_type=constants.CLIENT_TYPES.cl,
            image=participant.cl_image[-constants.MAX_LABEL_LENGTH :],
            connected_client=el_context.client_name if el_context != None else "none",
            extra_labels=participant.cl_extra_labels
            | {constants.NODE_INDEX_LABEL_KEY: str(participant_index + 1)},
            supernode=participant.supernode,
        ),
        "tolerations": tolerations,
        "node_selectors": node_selectors,
    }

    if len(participant.cl_devices) > 0:
        config_args["devices"] = participant.cl_devices

    if not participant.skip_start:
        config_args["ready_conditions"] = cl_node_ready_conditions.get_ready_conditions(
            constants.HTTP_PORT_ID
        )

    if int(participant.cl_min_cpu) > 0:
        config_args["min_cpu"] = int(participant.cl_min_cpu)
    if int(participant.cl_max_cpu) > 0:
        config_args["max_cpu"] = int(participant.cl_max_cpu)
    if int(participant.cl_min_mem) > 0:
        config_args["min_memory"] = int(participant.cl_min_mem)
    if int(participant.cl_max_mem) > 0:
        config_args["max_memory"] = int(participant.cl_max_mem)

    return ServiceConfig(**config_args)

def get_cl_context(
    plan,
    service_name,
    service,
    participant,
    snooper_el_engine_context,
    node_keystore_files,
    node_selectors,
):
    beacon_http_port = service.ports[constants.HTTP_PORT_ID]
    beacon_metrics_port = service.ports[constants.METRICS_PORT_ID]
    beacon_http_url = "http://{0}:{1}".format(service.name, beacon_http_port.number)
    beacon_metrics_url = "{0}:{1}".format(service.name, beacon_metrics_port.number)

    if participant.skip_start:
        beacon_node_enr = ""
        beacon_multiaddr = ""
        beacon_peer_id = ""
    else:
        beacon_node_identity_recipe = GetHttpRequestRecipe(
            endpoint="/eth/v1/node/identity",
            port_id=constants.HTTP_PORT_ID,
            extract = {
                "enr": ".data.enr",
                "peer_id": ".data.peer_id",
                "multiaddr": ".data.p2p_addresses[0]",
            }
        )
        response = plan.request(
            recipe=beacon_node_identity_recipe, service_name=service_name
        )
        beacon_node_enr = response["extract.enr"]
        beacon_multiaddr = response["extract.multiaddr"]
        beacon_peer_id = response["extract.peer_id"]

    ream_node_metrics_info = node_metrics.new_node_metrics_info(
        service_name, BEACON_METRICS_PATH, beacon_metrics_url
    )
    nodes_metrics_info = [ream_node_metrics_info]

    return cl_context.new_cl_context(
        client_name="ream",
        enr=beacon_node_enr,
        ip_addr=service.name,
        http_port=beacon_http_port.number,
        beacon_http_url=beacon_http_url,
        cl_nodes_metrics_info=nodes_metrics_info,
        beacon_service_name=service_name,
        multiaddr=beacon_multiaddr,
        peer_id=beacon_peer_id,
        snooper_enabled=participant.snooper_enabled,
        snooper_el_engine_context=snooper_el_engine_context,
        validator_keystore_files_artifact_uuid=node_keystore_files.files_artifact_uuid
        if node_keystore_files
        else "",
        supernode=participant.supernode,
    )

def new_ream_launcher(el_cl_genesis_data, jwt_file):
    return struct(
        el_cl_genesis_data=el_cl_genesis_data,
        jwt_file=jwt_file,
    )

def get_blobber_config(
    plan,
    participant,
    beacon_service_name,
    beacon_http_url,
    node_keystore_files,
    node_selectors,
):
    return None
