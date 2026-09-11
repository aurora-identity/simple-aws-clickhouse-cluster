# One Makefile for both places the cluster runs. The deploy, schema and test targets act on
# whatever cluster kubectl currently points at; local-up and aws-kube are what point it.
#
#   make local-up       a kind cluster on this machine, shaped like the AWS one
#   make local-down     delete it
#
#   make aws-plan       CloudFormation change set you can read before anything is built
#   make aws-apply      build it
#   make aws-kube       point kubectl at the EKS cluster
#   make aws-destroy    tear it all down, Kubernetes first
#
#   make deploy         the ConfigMaps and the Kubernetes manifest
#   make schema         apply schema/*.sql through a Job
#   make test           run tests/test-cluster.sh over port-forwards
#   make undeploy       remove ClickHouse from the current cluster

-include .env
export

NAMESPACE := clickhouse
KIND_CLUSTER := clickhouse

# Local

local-up:
	kind create cluster --config kubernetes/kind.yaml
	kubectl get nodes -L role,topology.kubernetes.io/zone

local-down:
	kind delete cluster --name $(KIND_CLUSTER)

# ClickHouse, on whichever cluster kubectl points at

deploy:
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap clickhouse-config -n $(NAMESPACE) --from-file=config/server/config.d --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap clickhouse-users -n $(NAMESPACE) --from-file=config/server/users.d --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap keeper-config -n $(NAMESPACE) --from-file=config/keeper --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f kubernetes/clickhouse.yaml
	kubectl rollout status statefulset/keeper -n $(NAMESPACE) --timeout=300s
	kubectl rollout status statefulset/clickhouse -n $(NAMESPACE) --timeout=300s
	kubectl get pods -n $(NAMESPACE) -o wide

schema:
	kubectl create configmap clickhouse-schema -n $(NAMESPACE) --from-file=schema --dry-run=client -o yaml | kubectl apply -f -
	kubectl delete job apply-schema -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f kubernetes/schema-job.yaml
	kubectl wait --for=condition=complete job/apply-schema -n $(NAMESPACE) --timeout=300s
	kubectl logs job/apply-schema -n $(NAMESPACE)

test:
	@kubectl port-forward -n $(NAMESPACE) pod/clickhouse-0 18123:8123 >/dev/null 2>&1 & PF0=$$!; \
	kubectl port-forward -n $(NAMESPACE) pod/clickhouse-1 18124:8123 >/dev/null 2>&1 & PF1=$$!; \
	trap 'kill $$PF0 $$PF1 2>/dev/null' EXIT; \
	sleep 3; \
	REPLICA_0=http://localhost:18123 REPLICA_1=http://localhost:18124 tests/test-cluster.sh

undeploy:
	kubectl delete job apply-schema -n $(NAMESPACE) --ignore-not-found
	kubectl delete --ignore-not-found -f kubernetes/clickhouse.yaml
	kubectl delete pvc --all -n $(NAMESPACE) --ignore-not-found

# AWS. Reads AWS_REGION and STACK_NAME from .env; see .env.example.

STACK_NAME ?= clickhouse
CHANGE_SET := $(STACK_NAME)-plan
BOOTSTRAP_STACK := $(STACK_NAME)-role

# Who may reach the Kubernetes API from the internet. Your current address unless .env says
# otherwise. Note the escaped comma: CloudFormation splits the list on commas itself.
comma := ,
API_ALLOWED_CIDRS ?= $(shell curl -s https://checkip.amazonaws.com)/32
API_CIDRS_PARAM := $(subst $(comma),\\$(comma),$(API_ALLOWED_CIDRS))

DEPLOY_ROLE_ARN = $(shell aws cloudformation describe-stacks \
	--stack-name $(BOOTSTRAP_STACK) --region $(AWS_REGION) \
	--query "Stacks[0].Outputs[?OutputKey=='DeploymentRoleArn'].OutputValue" \
	--output text 2>/dev/null)

aws-bootstrap:
	aws cloudformation deploy \
		--region $(AWS_REGION) \
		--stack-name $(BOOTSTRAP_STACK) \
		--template-file aws/cloudformation/bootstrap-role.yaml \
		--capabilities CAPABILITY_NAMED_IAM \
		--parameter-overrides TrustedUserArn=$$(aws sts get-caller-identity --query Arn --output text)

aws-plan: aws-bootstrap
	@role="$(DEPLOY_ROLE_ARN)"; \
	if [ -z "$$role" ] || [ "$$role" = "None" ]; then echo "Bootstrap stack '$(BOOTSTRAP_STACK)' not found."; exit 1; fi; \
	echo "Using role $$role"; \
	change_type="CREATE"; \
	if aws cloudformation describe-stacks --region $(AWS_REGION) --stack-name $(STACK_NAME) >/dev/null 2>&1; then change_type="UPDATE"; fi; \
	aws cloudformation create-change-set \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--change-set-name $(CHANGE_SET) \
		--change-set-type $$change_type \
		--template-body file://aws/cloudformation/clickhouse-stack.yaml \
		--role-arn $$role \
		--parameters ParameterKey=EksClusterName,ParameterValue=$(STACK_NAME) \
		             ParameterKey=ApiAllowedCidrs,ParameterValue="$(API_CIDRS_PARAM)" \
		--capabilities CAPABILITY_NAMED_IAM; \
	aws cloudformation wait change-set-create-complete --region $(AWS_REGION) --stack-name $(STACK_NAME) --change-set-name $(CHANGE_SET); \
	aws cloudformation describe-change-set --region $(AWS_REGION) --stack-name $(STACK_NAME) --change-set-name $(CHANGE_SET)

aws-apply:
	aws cloudformation execute-change-set --region $(AWS_REGION) --stack-name $(STACK_NAME) --change-set-name $(CHANGE_SET)
	@echo "Waiting for the stack. EKS takes ten to fifteen minutes."
	@status=$$(aws cloudformation describe-stacks --region $(AWS_REGION) --stack-name $(STACK_NAME) --query 'Stacks[0].StackStatus' --output text); \
	case "$$status" in CREATE_*|REVIEW_IN_PROGRESS) waiter=stack-create-complete;; *) waiter=stack-update-complete;; esac; \
	aws cloudformation wait $$waiter --region $(AWS_REGION) --stack-name $(STACK_NAME) || \
	{ echo "Stack failed. The reason is in:"; echo "  aws cloudformation describe-stack-events --region $(AWS_REGION) --stack-name $(STACK_NAME) --query 'StackEvents[?ResourceStatus==\`CREATE_FAILED\`].[LogicalResourceId,ResourceStatusReason]' --output table"; exit 1; }

aws-kube:
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(STACK_NAME) --role-arn $(DEPLOY_ROLE_ARN)
	kubectl get nodes -L role,topology.kubernetes.io/zone

aws-destroy:
	@if kubectl get nodes >/dev/null 2>&1; then $(MAKE) undeploy; else echo "Cluster unreachable; assuming its resources are already gone."; fi
	@for stack in $(STACK_NAME) $(BOOTSTRAP_STACK); do \
		if aws cloudformation describe-stacks --region $(AWS_REGION) --stack-name $$stack >/dev/null 2>&1; then \
			echo "Deleting $$stack..."; \
			aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $$stack; \
			aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $$stack; \
		else \
			echo "Stack $$stack does not exist. Skipping."; \
		fi; \
	done

.PHONY: local-up local-down deploy schema test undeploy aws-bootstrap aws-plan aws-apply aws-kube aws-destroy
