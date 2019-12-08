#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=en_US.UTF-8

# Usage: run-network.sh <COMMAND> <DATA_DIR>
COMMAND=${1:-"pull,accounts,run-validator,run-proxy,status,print-env"}
DATA_DIR=${2:-"/tmp/celo/network"}

export CELO_IMAGE=${3:-"us.gcr.io/celo-testnet/celo-node:baklava"}
export NETWORK_ID=${4:-"12219"}
export NETWORK_NAME=${5:-"baklava"}
export DEFAULT_PASSWORD=${6:-"1234"}
export CELO_IMAGE_ATTESTATION=${7:-"us.gcr.io/celo-testnet/celo-monorepo@sha256:90ea6739f9d239218245b5dce30e1bb5f05ac8dbc59f8e6f315502635c05ccb1"}
export CELO_PROVIDER=${8:-"https://baklava-forno.celo-testnet.org/"} # https://berlintestnet001-forno.celo-networks-dev.org/
export DATABASE_URL=${9:-"sqlite://db/attestation.db"}

export VALIDATOR_NAME=johndoe_$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)
export VALIDATOR_GROUP_NAME=tijuana_$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)

export CELOCLI="npx celocli"

export TWILIO_MESSAGING_SERVICE_SID=MG00000000000000000000000000000000
export TWILIO_ACCOUNT_SID=AC00000000000000000000000000000000
export TWILIO_BLACKLIST=""
export TWILIO_AUTH_TOKEN="ffffffffffffffffffffffffffffffff"

export ETHSTATS_ARG="@$NETWORK_NAME-ethstats.celo-testnet.org"

ACCOUNTS_DIR="${DATA_DIR}/accounts"
VALIDATOR_DIR="${DATA_DIR}/validator"
PROXY_DIR="${DATA_DIR}/proxy"
FULLNODE_DIR="${DATA_DIR}/fullnode"
ATTESTATION_DIR="${DATA_DIR}/attestations"


mkdir -p $DATA_DIR
mkdir -p $ACCOUNTS_DIR
mkdir -p $VALIDATOR_DIR
mkdir -p $PROXY_DIR
mkdir -p $FULLNODE_DIR
mkdir -p $ATTESTATION_DIR

__PWD=$PWD

__DIRNAME=$(dirname $0)

if [[ -f $__DIRNAME/validator-config.rc ]]; then

    echo -e "Loading config from $__DIRNAME/validator-config.rc"
    set -o allexport
    source $__DIRNAME/validator-config.rc
    set +o allexport
fi

if [[ ! -v CELO_VALIDATOR_NAME ]]; then
  echo "Enter a name for your validator"
  read CELO_VALIDATOR_NAME
fi

export PROXY_ETHSTATS="$CELO_VALIDATOR_NAME-proxy$ETHSTATS_ARG"
export VALIDATOR_ETHSTATS="$CELO_VALIDATOR_NAME$ETHSTATS_ARG"

#### Internal functions
remove_containers () {
    echo -e "\tRemoving previous celo containers"
    docker rm -f celo-proxy celo-validator celo-attestation-service celo-accounts || echo -e "Containers removed"
}

download_genesis () {
    echo -e "\tDownload genesis.json and static-nodes.json to the container"
    docker run -v $PWD/proxy:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c "wget https://www.googleapis.com/storage/v1/b/static_nodes/o/$NETWORK_NAME?alt=media -O /root/.celo/static-nodes.json"
    docker run -v $PWD/proxy:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c "wget https://www.googleapis.com/storage/v1/b/genesis_blocks/o/$NETWORK_NAME?alt=media -O /root/.celo/genesis.json"
    
    docker run -v $PWD/validator:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c "wget https://www.googleapis.com/storage/v1/b/genesis_blocks/o/$NETWORK_NAME?alt=media -O /root/.celo/genesis.json"

}

make_status_requests () {
    echo -e "Checking Proxy and Validator state:"
    
    echo -n "* eth_blockNumber:"
    curl -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' -H "Content-Type: application/json" localhost:8545
    
    echo -n "* Validator net_peerCount:"
    curl -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":74}' -H "Content-Type: application/json" localhost:8545
    
    echo -n "* Validator eth_mining:"
    curl -X POST --data '{"jsonrpc":"2.0","method":"eth_mining","params":[],"id":1}' -H "Content-Type: application/json" localhost:8545

    echo -e ""
    
}

initialize_geth () {

    echo -e "\tDownload genesis.json and static-nodes.json to the container"
    docker run -v $PWD:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c "wget https://www.googleapis.com/storage/v1/b/genesis_blocks/o/$NETWORK_NAME?alt=media -O /root/.celo/genesis.json"
    docker run -v $PWD:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c "wget https://www.googleapis.com/storage/v1/b/static_nodes/o/$NETWORK_NAME?alt=media -O /root/.celo/static-nodes.json"
    
    docker run -v $PWD:/root/.celo $CELO_IMAGE init /root/.celo/genesis.json
}

#### Main 


if [[ $COMMAND == *"help"* ]]; then
    
    echo -e "Script for running a local validator network using docker containers. This script runs:"
    echo -e "\t - A Validator node"
    echo -e "\t - A Proxy node"
    echo -e "\t - An attestation service\n"

    echo -e "Options:"
    echo -e "$0 <COMMAND> <DATA_DIR> <CELO_IMAGE> <NETWORK_ID> <NETWORK_NAME> <PASSWORD>"
    echo -e "\t - Command; comma separated list of actions to execute. Options are: help, pull, clean, accounts, run-validator, run-proxy, run-attestation, run-fullnode, status, print-env, get-cooking. Default: pull,accounts,run-validator,run-proxy,status"
    echo -e "\t - Data Dir; Local folder where will be created the data dir for the nodes. Default: /tmp/celo/network"
    echo -e "\t - Celo Image; Image to download"
    echo -e "\t - Celo Network; Docker image network to use (typically alfajores or baklava, but you can use a commit). "
    echo -e "\t - Network Id; 31417 for integration, 44785 for alfajores, etc."
    echo -e "\t - Network Name; integration by default"
    echo -e "\t - Password; Password to use during the creation of accounts"
    
    echo -e "\n**********\n\nExamples:\n"
    echo -e "\tIf you want to create the local accounts, run a Proxy and a Validator connected to it:"
    echo -e "\t$0 pull,accounts,run-validator,run-proxy,status,print-env"
    
    echo -e "\n\tIf you have already your accounts, proxy and validator set up, you can run the following command to run TGCSO"
    echo -e "\t$0 get-cooking"
    
    echo -e "\n\tIf you want to play TGCSO without being re-using your previously created accounts without restarting the proxy and validator, it's recommended to copy all your CELO environment variables in the 'validator-config.rc' file. The script will source the variables from there. "

    echo -e "\n"
    exit 0
fi

if [[ $COMMAND == *"pull"* ]]; then

    echo -e "* Downloading docker image: $CELO_IMAGE"
    docker pull $CELO_IMAGE

fi


if [[ $COMMAND == *"clean"* ]]; then

    echo -e "* Removing data dir $DATA_DIR"
    rm -rf $DATA_DIR/*
    mkdir -p $DATA_DIR
    mkdir -p $ACCOUNTS_DIR
    mkdir -p $VALIDATOR_DIR
    mkdir -p $PROXY_DIR
    mkdir -p $FULLNODE_DIR
    mkdir -p $ATTESTATION_DIR
fi


if [[ $COMMAND == *"accounts"* ]]; then

    echo -e "* Creating accounts ..."
    cd $ACCOUNTS_DIR

    docker rm -f celo-accounts || echo -e "Containers removed"

    export CELO_VALIDATOR_ADDRESS=$(docker run -v $PWD:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c " printf '%s\n' $DEFAULT_PASSWORD $DEFAULT_PASSWORD | geth account new " |tail -1| cut -d'{' -f 2| tr -cd "[:alnum:]\n" )
    export CELO_VALIDATOR_GROUP_ADDRESS=$(docker run -v $PWD:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c " printf '%s\n' $DEFAULT_PASSWORD $DEFAULT_PASSWORD | geth account new " |tail -1| cut -d'{' -f 2| tr -cd "[:alnum:]\n" )
    
    initialize_geth
    
    cd $VALIDATOR_DIR
    export CELO_VALIDATOR_SIGNER_ADDRESS=$(docker run -v $PWD:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c " printf '%s\n' $DEFAULT_PASSWORD $DEFAULT_PASSWORD | geth account new " |tail -1| cut -d'{' -f 2| tr -cd "[:alnum:]\n" )
        
    initialize_geth
    
    echo -e "\tCELO_VALIDATOR_ADDRESS=$CELO_VALIDATOR_ADDRESS"
    echo -e "\tCELO_VALIDATOR_GROUP_ADDRESS=$CELO_VALIDATOR_GROUP_ADDRESS"
    echo -e "\tCELO_VALIDATOR_SIGNER_ADDRESS=$CELO_VALIDATOR_SIGNER_ADDRESS"

    cd $ACCOUNTS_DIR

    echo -e "Starting local Docker holding the accounts. You can attach to it running 'screen -r -S celo-accounts'\n"
    screen -S celo-accounts -d -m docker run --name celo-accounts --restart always -p 8545:8545 -v $PWD:/root/.celo $CELO_IMAGE --verbosity 3 --networkid $NETWORK_ID --syncmode full --rpc --rpcaddr 0.0.0.0 --rpcapi eth,net,web3,debug,admin,personal
    


fi

if [[ $COMMAND == *"run-proxy"* ]]; then

    echo -e "* Let's run the Proxy ..."
    cd $PROXY_DIR
    
    docker rm -f celo-proxy || echo -e "Containers removed"

    initialize_geth

    screen -S celo-proxy -d -m docker run --name celo-proxy --restart always -p 30303:30303 -p 30303:30303/udp -p 30503:30503 -p 30503:30503/udp -v $PWD:/root/.celo $CELO_IMAGE --verbosity 3 --networkid $NETWORK_ID --syncmode full --proxy.proxy --proxy.proxiedvalidatoraddress $CELO_VALIDATOR_SIGNER_ADDRESS --proxy.internalendpoint :30503 --etherbase $CELO_VALIDATOR_SIGNER_ADDRESS --ethstats=$PROXY_ETHSTATS
    
    sleep 5s
    export PROXY_ENODE=$(docker exec celo-proxy geth --exec "admin.nodeInfo['enode'].split('//')[1].split('@')[0]" attach | tr -d '"')
    export PROXY_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' celo-proxy)
    echo -e "The Proxy should be starting. You can attach to it running 'screen -r -S celo-proxy'\n"

fi





if [[ $COMMAND == *"run-validator"* ]]; then

    echo -e "* Let's run the Validator ..."
    cd $VALIDATOR_DIR

    docker rm -f celo-validator || echo -e "Containers removed"

    echo -e "\tGenerating the Validator Proof of Possesion"

    __POS=$(docker run -v $PWD:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c " printf '%s\n' $DEFAULT_PASSWORD $DEFAULT_PASSWORD | geth account proof-of-possession $CELO_VALIDATOR_SIGNER_ADDRESS $CELO_VALIDATOR_ADDRESS "| tail -2 )
    export CELO_VALIDATOR_SIGNER_PUBLIC_KEY=$(echo $__POS | cut -d' ' -f 6| tr -cd "[:alnum:]\n" )
    export CELO_VALIDATOR_SIGNER_SIGNATURE=$(echo $__POS | cut -d' ' -f 2| tr -cd "[:alnum:]\n" )
    
    echo -e "\tCELO_VALIDATOR_SIGNER_PUBLIC_KEY=$CELO_VALIDATOR_SIGNER_PUBLIC_KEY"
    echo -e "\tCELO_VALIDATOR_SIGNER_SIGNATURE=$CELO_VALIDATOR_SIGNER_SIGNATURE"

    
    echo -e "\tGenerating the Validator Proof of Possesion of the BLS key"
    __BLS=$(docker run -v $PWD:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c " printf '%s\n' $DEFAULT_PASSWORD $DEFAULT_PASSWORD | geth account proof-of-possession $CELO_VALIDATOR_SIGNER_ADDRESS $CELO_VALIDATOR_ADDRESS --bls "| tail -2 )
    export CELO_VALIDATOR_SIGNER_BLS_PUBLIC_KEY=$(echo $__BLS | cut -d' ' -f 6| tr -cd "[:alnum:]\n" )
    export CELO_VALIDATOR_SIGNER_BLS_SIGNATURE=$(echo $__BLS | cut -d' ' -f 2| tr -cd "[:alnum:]\n" )
    
    echo -e "\tCELO_VALIDATOR_SIGNER_BLS_PUBLIC_KEY=$CELO_VALIDATOR_SIGNER_BLS_PUBLIC_KEY"
    echo -e "\tCELO_VALIDATOR_SIGNER_BLS_SIGNATURE=$CELO_VALIDATOR_SIGNER_BLS_SIGNATURE"
    
    
    echo -e "\tConnecting Validator to Proxy running at enode://$PROXY_ENODE@$PROXY_IP"
    docker run -v $PWD:/root/.celo --entrypoint sh --rm $CELO_IMAGE -c "echo $DEFAULT_PASSWORD > /root/.celo/.password"
    screen -S celo-validator -d -m docker run --name celo-validator --restart always -p 30303:30303 -p 30303:30303/udp -v $PWD:/root/.celo $CELO_IMAGE --verbosity 3 --networkid $NETWORK_ID --syncmode full --mine --istanbul.blockperiod=5 --istanbul.requesttimeout=3000 --etherbase $CELO_VALIDATOR_SIGNER_ADDRESS --nodiscover --proxy.proxied --proxy.proxyenodeurlpair=enode://$PROXY_ENODE@$PROXY_IP:30503\;enode://$PROXY_ENODE@$PROXY_IP:30303  --unlock=$CELO_VALIDATOR_SIGNER_ADDRESS --password /root/.celo/.password --ethstats=$VALIDATOR_ETHSTATS

    sleep 5s
     
    echo -e "The Validator should be starting. You can attach to it running 'screen -r -S celo-validator'\n"
    
fi

if [[ $COMMAND == *"run-attestation"* ]]; then

    echo -e "* Let's run the attestation service ..."
    docker rm -f celo-attestation || echo -e "Containers removed"

    echo -e "\tPulling docker image: $CELO_IMAGE_ATTESTATION"
    docker pull $CELO_IMAGE_ATTESTATION
    
    export ATTESTATION_KEY=0x$($CELOCLI account:new| tail -3| head -1| cut -d' ' -f 2| tr -cd "[:alnum:]\n")
    echo -e "\tATTESTATION_KEY=$ATTESTATION_KEY"
        
    screen -S attestation-service -d -m docker run --name celo-attestation-service -v $PWD/attestations:/celo-monorepo/packages/attestation-service/db -d --restart always --entrypoint /bin/bash -e ATTESTATION_SIGNER_ADDRESS=0x$CELO_ATTESTATION_SIGNER_ADDRESS -e CELO_VALIDATOR_ADDRESS=0x$CELO_VALIDATOR_ADDRESS -e CELO_PROVIDER=$CELO_PROVIDER -e DATABASE_URL=$DATABASE_URL -e SMS_PROVIDERS=twilio -e TWILIO_MESSAGING_SERVICE_SID=$TWILIO_MESSAGING_SERVICE_SID -e TWILIO_ACCOUNT_SID=$TWILIO_ACCOUNT_SID -e TWILIO_BLACKLIST=$TWILIO_BLACKLIST -e TWILIO_AUTH_TOKEN=$TWILIO_AUTH_TOKEN -p 3000:80 $CELO_IMAGE_ATTESTATION -c " cd /celo-monorepo/packages/attestation-service && yarn run db:migrate && yarn start "
    
    echo -e "\tAttestation service should be running, you can check running 'screen -ls'"
    echo -e "\tYou can re-attach to the attestation-service running:"
    echo -e "\t 'screen -r -S celo-attestation-service'\n"

fi

if [[ $COMMAND == *"status"* ]]; then

    make_status_requests

fi

if [[ $COMMAND == *"run-fullnode"* ]]; then

    echo -e "* Let's run the full node ..."
    cd $DATA_DIR

    docker rm -f celo-fullnode || echo -e "Container removed"

    export CELO_ACCOUNT_ADDRESS=$($CELOCLI account:new |tail -1| cut -d' ' -f 2| tr -cd "[:alnum:]\n")

    docker run -v $PWD/fullnode:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c "wget https://www.googleapis.com/storage/v1/b/static_nodes/o/$NETWORK_NAME?alt=media -O /root/.celo/static-nodes.json"

    docker run -v $PWD/fullnode:/root/.celo --entrypoint /bin/sh -it $CELO_IMAGE -c "wget https://www.googleapis.com/storage/v1/b/genesis_blocks/o/$NETWORK_NAME?alt=media -O /root/.celo/genesis.json"
    docker run -v $PWD/fullnode:/root/.celo $CELO_IMAGE init /root/.celo/genesis.json

    echo -e "\tStarting the Full Node"

    screen -S celo-fullnode -d -m docker run --name celo-fullnode --restart always -p 127.0.0.1:8545:8545 -p 127.0.0.1:8546:8546 -p 30303:30303 -p 30303:30303/udp -v $PWD/fullnode:/root/.celo $CELO_IMAGE --verbosity 3 --networkid $NETWORK_ID --syncmode full --rpc --rpcaddr 0.0.0.0 --rpcapi eth,net,web3,debug,admin,personal --lightserv 90 --lightpeers 1000 --maxpeers 1100 --etherbase $CELO_ACCOUNT_ADDRESS --ethstats=fullnode-$ETHSTATS_ARG
    
    sleep 2s

    echo -e "\tEverything should be running, you can check running 'screen -ls'"
    screen -ls

    echo -e "\tYou can re-attach to the full node running:"
    echo -e "\t 'screen -r -S celo-fullnode'\n"
fi

if [[ $COMMAND == *"print-env"* ]]; then

    echo -e "\n************************************************************************\n"
    echo -e "Celo Environment Variables (copy to validator-config.rc to re-use them!):\n\n"
    echo -e "CELO_VALIDATOR_ADDRESS=$CELO_VALIDATOR_ADDRESS"
    echo -e "CELO_VALIDATOR_GROUP_ADDRESS=$CELO_VALIDATOR_GROUP_ADDRESS"
    echo -e "CELO_VALIDATOR_SIGNER_ADDRESS=$CELO_VALIDATOR_SIGNER_ADDRESS"
    echo -e "CELO_VALIDATOR_SIGNER_PUBLIC_KEY=$CELO_VALIDATOR_SIGNER_PUBLIC_KEY"
    echo -e "CELO_VALIDATOR_SIGNER_SIGNATURE=$CELO_VALIDATOR_SIGNER_SIGNATURE"
    echo -e "CELO_VALIDATOR_SIGNER_BLS_PUBLIC_KEY=$CELO_VALIDATOR_SIGNER_BLS_PUBLIC_KEY"
    echo -e "CELO_VALIDATOR_SIGNER_BLS_SIGNATURE=$CELO_VALIDATOR_SIGNER_BLS_SIGNATURE"
    echo -e "CELO_VALIDATOR_NAME=$CELO_VALIDATOR_NAME"
    echo -e "\n************************************************************************\n"

fi

if [[ $COMMAND == *"get-cooking"* ]]; then

    echo -e "* Prepping validator for The Great Celo Stake Off..."
    
    echo -e "\t1. Unlocking accounts .."
    $CELOCLI account:unlock --account $CELO_VALIDATOR_GROUP_ADDRESS --password $DEFAULT_PASSWORD
    $CELOCLI account:unlock --account $CELO_VALIDATOR_ADDRESS --password $DEFAULT_PASSWORD
    
    echo -e "\t2. Registering accounts .."
    $CELOCLI account:register --from $CELO_VALIDATOR_GROUP_ADDRESS --name $VALIDATOR_GROUP_NAME || echo -e "$CELO_VALIDATOR_GROUP_ADDRESS already registered"
    $CELOCLI account:register --from $CELO_VALIDATOR_ADDRESS --name $VALIDATOR_NAME || echo -e "$CELO_VALIDATOR_ADDRESS already registered"
    
    echo -e "\t3. Locking Gold .."
    $CELOCLI lockedgold:lock --from $CELO_VALIDATOR_GROUP_ADDRESS --value 10000000000000000000000
    $CELOCLI lockedgold:lock --from $CELO_VALIDATOR_ADDRESS --value 10000000000000000000000

    echo -e "\t4. Run for election .."
    echo -e "\t   * Authorize the validator signing key"
    $CELOCLI account:authorize --from $CELO_VALIDATOR_ADDRESS --role validator --signature 0x$CELO_VALIDATOR_SIGNER_SIGNATURE --signer 0x$CELO_VALIDATOR_SIGNER_ADDRESS || echo -e "Validator Signing Key $CELO_VALIDATOR_ADDRESS already authorized"
    
    echo -e "\t   * Register Validator Group address"
    $CELOCLI validatorgroup:register --from $CELO_VALIDATOR_GROUP_ADDRESS --commission 0.1 || echo -e "Validator Group  $CELO_VALIDATOR_GROUP_ADDRESS already registered"

    echo -e "\t   * Register Validator"
    $CELOCLI validator:register --from $CELO_VALIDATOR_ADDRESS --ecdsaKey $CELO_VALIDATOR_SIGNER_PUBLIC_KEY --blsKey $CELO_VALIDATOR_SIGNER_BLS_PUBLIC_KEY --blsSignature $CELO_VALIDATOR_SIGNER_BLS_SIGNATURE || echo -e "Validator $CELO_VALIDATOR_GROUP_ADDRESS already registered"

    echo -e "\t   * Affiliate Validator with Validator Group"
    $CELOCLI validator:affiliate $CELO_VALIDATOR_GROUP_ADDRESS --from $CELO_VALIDATOR_ADDRESS

    echo -e "\t   * Accept affiliation"
    $CELOCLI validatorgroup:member --accept $CELO_VALIDATOR_ADDRESS --from $CELO_VALIDATOR_GROUP_ADDRESS

    echo -e "\t   * Vote Validator Group"
    $CELOCLI election:vote --from $CELO_VALIDATOR_ADDRESS --for $CELO_VALIDATOR_GROUP_ADDRESS --value 10000000000000000000000 || echo -e "Validator $CELO_VALIDATOR_ADDRESS already vote to $CELO_VALIDATOR_GROUP_ADDRESS"
    $CELOCLI election:vote --from $CELO_VALIDATOR_GROUP_ADDRESS --for $CELO_VALIDATOR_GROUP_ADDRESS --value 10000000000000000000000 || echo -e "Validator $CELO_VALIDATOR_ADDRESS already vote to $CELO_VALIDATOR_GROUP_ADDRESS"
    
    echo -e "\t State of the validation elections"
    $CELOCLI election:list

    echo -e "\t Current elected validators"
    $CELOCLI election:current

fi

cd $__PWD





