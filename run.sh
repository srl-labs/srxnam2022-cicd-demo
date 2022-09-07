#!/bin/bash

set -e

gnmic_cmd="gnmic --tls-ca clab-srx2022/ca/root/root-ca.pem -u admin -p admin"

printf "gnmic version : $(gnmic version | grep version | awk '{print $NF}')\n"
printf "clab version  : $(sudo containerlab version | grep version | awk '{print $NF}')\n"

# deploy the lab.
# if you have limited compute resources, limit the number of workers by
# uncommenting the `--max-workers 4` flag
sudo clab deploy -t srx2022.clab.gotmpl --reconfigure #--max-workers 4

# get SR Linux Nodes names and join them with a comma
srl_nodes=$(docker ps -f label=containerlab=srx2022 -f label=clab-node-kind=srl --format {{.Names}} | paste -s -d, -)

# configure interfaces via gNMI 
${gnmic_cmd} \
      --log \
      -a ${srl_nodes} \
      -e json_ietf \
      set \
      --request-file config/1.interfaces/interfaces_template.gotmpl \
      --request-file config/1.interfaces/subinterfaces_template.gotmpl \
      --request-vars config/1.interfaces/interfaces_template_vars.yaml

# configure routing policy via gNMI 
${gnmic_cmd} \
      --log \
      -a ${srl_nodes} \
      -e json_ietf \
      set \
      --request-file config/2.routing-policy/routing_policy_prefix_set_template.gotmpl \
      --request-file config/2.routing-policy/routing_policy_policy_template.gotmpl \
      --request-vars config/2.routing-policy/routing_policy_vars.yaml


# # configure network-instance via gNMI 
${gnmic_cmd} \
      --log \
      -a ${srl_nodes} \
      -e json_ietf \
      set \
      --request-file config/3.network-instance/network_instance_template.gotmpl \
      --request-file config/3.network-instance/network_instance_bgp_template.gotmpl \
      --request-vars config/3.network-instance/network_instance_template_vars.yaml

printf "\n"
printf "$(date): Waiting 5s before checking nodes BGP status\n"
sleep 5

for node in $(docker ps -f label=clab-node-kind=srl -f label=containerlab=srx2022 --format {{.Names}})
do 
  bgp_state=$(${gnmic_cmd} \
                  -a $node \
                  -e ascii \
                  --format flat \
                  get \
                  --path /network-instance[name=default]/protocols/bgp/oper-state | awk '{print $NF}')
  
  
  if [ $bgp_state != "up" ]; then
    printf "unexpected BGP state for node $node : ${bgp_state^^} (ノ ゜Д゜)ノ ︵ ┻━┻\n"
    exit 1
  fi
  printf "$(date): \\U1F44D $node BGP state is ${bgp_state^^} \n"
done

printf "\n"
printf "$(date): Waiting 60s for BGP sessions to be established\n"
sleep 60

expected_num_neighbors=$(expr $(yq e '.super_spines.num' srx2022.clab_vars.yaml) + $(yq e '.pods.leaves.num' srx2022.clab_vars.yaml))
echo "$(date): expecting $expected_num_neighbors neighbors per spine..."
for node in $(docker ps -f label=clab-node-kind=srl -f label=containerlab=srx2022 -f label=clab-node-group=spine --format {{.Names}})
do
num_neighbors=$(
      gnmic -a $node \
            --tls-ca clab-srx2022/ca/root/root-ca.pem \
            -u admin \
            -p admin \
            -e ascii \
            --format flat \
            get \
            --path /network-instance[name=default]/protocols/bgp/neighbor/ipv4-unicast/oper-state | grep neighbor | wc -l
            )
      if [ "$num_neighbors" -ne "$expected_num_neighbors" ]
      then
        printf "unexpected number of neighbors for node $node, expected $expected_num_neighbors, got $num_neighbors (ノ ゜Д゜)ノ ︵ ┻━┻\n"
        exit 1
      fi
      printf "$(date): \\U1F44D $node has $num_neighbors BGP neighbors \n"
done
