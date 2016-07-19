#!/bin/bash

########################################################################################
export DOCKERCLOUD_USER=${WERCKER_BLUEGREEN_USER:-}
export DOCKERCLOUD_PASS=${WERCKER_BLUEGREEN_PASS:-}
export DOCKERCLOUD_LOAD_BALANCER_NAME=${WERCKER_BLUEGREEN_LOAD_BALANCER_NAME:-"haproxy"}
export DOCKERCLOUD_BACKEND_NAMES=${WERCKER_BLUEGREEN_BACKEND_NAMES:-}
export BLUEGREEN_MINIMUM_SCALE=${WERCKER_BLUEGREEN_MINIMUM_SCALE:-1}
export BLUEGREEN_ROLLBACK=${WERCKER_BLUEGREEN_ROLLBACK:-}
export BLUEGREEN_ACTION_TIMEOUT=${WERCKER_BLUEGREEN_ACTION_TIMEOUT:-45}
########################################################################################

if [[ -z "$DOCKERCLOUD_USER" ]] || [[ -z "$DOCKERCLOUD_PASS" ]]; then
	fail "Please declare DOCKERCLOUD_USER and DOCKERCLOUD_PASS env variables or user/pass step parameters"
fi

shopt -s nocasematch
case "$BLUEGREEN_ROLLBACK" in
	false|no|0)	BLUEGREEN_ROLLBACK="";;
esac

export PATH=$WERCKER_STEP_ROOT/bin:$PATH

EXIT_CODE_DEPENDENCY=126
EXIT_CODE_TIMEOUT=5
EXIT_CODE_RESPONSE=4
EXIT_CODE_SERVICE_NOT_FOUND=3
EXIT_CODE_NEXT_BACKEND_NOT_FOUND=2

if ! type jq >/dev/null; then
	exit $EXIT_CODE_DEPENDENCY
fi

if ! type curl >/dev/null; then
	exit $EXIT_CODE_DEPENDENCY
fi

dockercloud_request() {	
	declare method=$1 url=$2 data=$3
	
	if [[ "$url" != "/api"* ]]; then
		url="/api/app/v1/$url"
	fi
	url=${url#/}
	
	local headers=$(mktemp -t headers.XXXX)
	
	local data=$(
		curl -s -D "$headers" \
			-A 'BlueGreen deploy (https://github.com/mlebkowski/wercker-step-bluegreen)' \
			-u "$DOCKERCLOUD_USER:$DOCKERCLOUD_PASS" \
			-X $method --data "$data" -H "Content-Type: application/json" \
			"https://cloud.docker.com/$url"
	)
	
	local response="$(head -1 "$headers" | tr -d '\r')"
	if [[ "$response" == "HTTP/1.1 4"* ]] || [[ "$response" == "HTTP/1.1 5"* ]]; then
		printf "!!! Invalid response received: %s\n" "$response" >&2
		rm $headers
		exit $EXIT_CODE_RESPONSE;
	fi
	
	if [[ "$response" == "HTTP/1.1 202"* ]]; then
		dockercloud_wait_for_finish "$headers"
	fi
	
	if [[ "$method" == "GET" ]]; then
		echo "$data"
	fi
	
	rm "$headers"
}

dockercloud_get() {	
	declare url=$1
	dockercloud_request GET "$url"
}

dockercloud_post() {	
	declare url=$1 data=${2:-}
	dockercloud_request POST "$url" "$data"
}

dockercloud_patch() {	
	declare url=$1 data=${2:-}
	dockercloud_request PATCH "$url" "$data"
}

dockercloud_wait_for_finish() {
	declare headers=$1

	local action=$(grep "X-DockerCloud-Action-URI" "$headers" | cut -b 27- | tr -d '\r')

	local i=0;
	while dockercloud_is_action_running "$action"; do
		if [[ $i -eq 0 ]]; then
			printf "    Waiting for action to finish: "
		fi

		sleep 3
		printf "." 
		
		if [[ $i -gt $BLUEGREEN_ACTION_TIMEOUT ]]; then
			printf "\n!!! Timed out waiting for action to finish\n" | indent
			exit $EXIT_CODE_TIMEOUT;
		fi
		i=$((i+3))
	done

	if [[ $i -gt 0 ]]; then
		printf "\n"	
	fi
}

dockercloud_is_action_running() {
	declare action=$1
	
	test "$(dockercloud_get "$action" | jq -rM .state)" == "In progress"
}

dockercloud_scale() {
	declare uuid=$1 scale=$2
	
	dockercloud_patch "service/$uuid/" "$(
		jq --arg SCALE "$scale" -crnM '{target_num_containers: $SCALE|tonumber}'
	)" >/dev/null
	
	dockercloud_post "service/$uuid/scale/"
}

find_service() {
	declare name=$1

	local data=$(jq -rM --arg name $name '.objects[] | select(.name == $name)')
	
	if [[ -z "$data" ]]; then
		printf "!!! Couldn’t find service named %s\n" "$name" | indent
		exit $EXIT_CODE_SERVICE_NOT_FOUND
	fi
	
	echo "$data"
}

get_load_balancer() {
	declare name=$1

	local uuid=$(find_service "$name" | jq -rM .uuid)
	
	if [[ -z "$uuid" ]]; then
		printf "!!! Cannot find load balancer using it’s name: %s\n" "$name" | indent
		exit $EXIT_CODE_SERVICE_NOT_FOUND
	fi

	dockercloud_get "service/$uuid/"
}

is_scalable() {
	test "$BLUEGREEN_MINIMUM_SCALE" -gt 0 && test "$(jq -rM .deployment_strategy)" != "EVERY_NODE"
}

service_name() {
	jq -M '.nickname + " [" + .name + " × " + (.target_num_containers|tostring) + "]"'
}

indent() {
	while read -r line; do
		if [[ "$line" == --* ]] || [[ "$line" == ==* ]]; then
			echo $line
		elif [[ "$line" == "!!!"* ]]; then
			echo $line >&2
		else
			echo "    $line"
		fi
	done
}


main() {
	
	declare name=$1
	
	local services=$(dockercloud_get "service/")
	
	printf -- '--> Searching for load balancer named %s\n' "$name" | indent
	
	local load_balancer=$(get_load_balancer "$name" <<<$services)
	if [[ -z "$load_balancer" ]]; then
		exit $EXIT_CODE_SERVICE_NOT_FOUND	
	fi
	
	local current_backend_name=$(jq -rM '(.linked_to_service|first).name' <<<$load_balancer)
	
	if [[ -n "$current_backend_name" ]]; then
		local current_backend=$(find_service "$current_backend_name" <<<$services)
	
		printf "Load Balancer %s is linked with %s containers\n" \
			"$(service_name <<<"$load_balancer")" \
			"$(service_name <<<"$current_backend")" \
			| indent
	else
		printf "Load Balancer %s is not linked to any backend\n" "$(service_name <<<"$load_balancer")" | indent
	fi

##########

	local available_backends=${DOCKERCLOUD_BACKEND_NAMES:-$(
		jq -rM '(.calculated_envvars|.[]|select(.key == "BLUEGREEN_SERVICE_NAMES")).value|split(" ")' <<<$load_balancer
	)}
	
	local next_backend_name=$(jq -rnM \
		--arg CURRENT "$current_backend_name" \
		--argjson INPUT "$available_backends" \
		--argjson DIRECTION "$(if [[ -n "$BLUEGREEN_ROLLBACK" ]]; then echo "-1"; else echo "+1"; fi)" \
		'if $INPUT|length > 0 then 
			$INPUT[(if $INPUT|index($CURRENT) == null then 0 else $INPUT|index($CURRENT) + $DIRECTION * 1 end) % ($INPUT|length)] 
		else "" end'
	)
	
	if [[ -z "$next_backend_name" ]]; then
		printf "!!! Couldn’t find next backend to use, did you specify the BLUEGREEN_SERVICE_NAMES env?\n" | indent >&2
		exit $EXIT_CODE_NEXT_BACKEND_NOT_FOUND
	fi

##########
	
	local next_backend=$(find_service $next_backend_name <<<$services)
	local next_backend_uuid=$(jq -rM .uuid <<<$next_backend)
	local load_balancer_uuid=$(jq -rM .uuid <<<$load_balancer)
	local current_backend_uuid=$(jq -rM .uuid <<<$current_backend)

	if [[ -z "$BLUEGREEN_ROLLBACK" ]]; then
		printf -- '--> Redeploying %s\n' "$(service_name <<<"$next_backend")" | indent
		dockercloud_post "service/$next_backend_uuid/redeploy/"
	fi
	
	if is_scalable <<<$next_backend; then
		local scale=$(jq -rM .target_num_containers <<<$current_backend)
		local current_scale=$(jq -rM .target_num_containers <<<$next_backend)

		if [[ $scale -lt $BLUEGREEN_MINIMUM_SCALE ]]; then
			scale=$BLUEGREEN_MINIMUM_SCALE
		fi

		if [[ $scale -le $current_scale ]]; then
			printf 'Next backend is already at %d scale or larger\n' $scale | indent
		else
			printf -- '--> Scaling to %d containers\n' $scale | indent
			dockercloud_scale "$next_backend_uuid" $scale
		fi
	fi
	
	printf -- '--> Switching to new backend: %s\n' "$next_backend_name" | indent
	dockercloud_patch "service/$load_balancer_uuid/" "$(
		jq -rM '{linked_to_service: [{ to_service: .resource_uri, name: .name }]}' <<<$next_backend
	)"

	if [[ -n "$current_backend_uuid" ]] && is_scalable <<<$current_backend && [[ $scale -ne 1 ]]; then
		printf -- '--> Scaling down previous backend\n' | indent
		dockercloud_scale "$current_backend_uuid" 1
	fi
	
	printf -- "==> Deployment finished!\n"
}

main $DOCKERCLOUD_LOAD_BALANCER_NAME
