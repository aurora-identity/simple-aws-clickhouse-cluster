# Run from this directory. Reads aws/.env; see .env.example for what it needs.
#
#   make bootstrap   the IAM role CloudFormation and kubectl will use
#   make plan        a change set you can read before anything is built
#   make apply       build it
#   make kube        point kubectl at the new cluster
#   make deploy      the ConfigMaps and the Kubernetes manifest
#   make schema      apply schema/*.sql through a Job
#   make test        run tests/test-cluster.sh over port-forwards
#   make destroy     tear everything down, Kubernetes first

include .env
export

STACK_NAME ?= clickhouse
CHANGE_SET ?= $(STACK_NAME)-plan
TEMPLATE ?= cloudformation/clickhouse-stack.yaml
BOOTSTRAP_STACK ?= $(STACK_NAME)-role
BOOTSTRAP_TEMPLATE ?= cloudformation/bootstrap-role.yaml
NAMESPACE := clickhouse

PARAMS := ParameterKey=EksClusterName,ParameterValue=$(STACK_NAME)

CURRENT_IDENTITY := $(shell aws sts get-caller-identity --query Arn --output text)

DEPLOY_ROLE_ARN ?= $(shell aws cloudformation describe-stacks \
	--stack-name $(BOOTSTRAP_STACK) --region $(AWS_REGION) \
	--query "Stacks[0].Outputs[?OutputKey=='DeploymentRoleArn'].OutputValue" \
	--output text 2>/dev/null)

bootstrap:
	aws cloudformation deploy \
		--region $(AWS_REGION) \
		--stack-name $(BOOTSTRAP_STACK) \
		--template-file $(BOOTSTRAP_TEMPLATE) \
		--capabilities CAPABILITY_NAMED_IAM \
		--parameter-overrides TrustedUserArn=$(CURRENT_IDENTITY)

plan: bootstrap
	$(eval ROLE := $(DEPLOY_ROLE_ARN))
	@if [ -z "$(ROLE)" ] || [ "$(ROLE)" = "None" ]; then \
		echo "Bootstrap stack '$(BOOTSTRAP_STACK)' not found. Run 'make bootstrap' first."; \
		exit 1; \
	fi; \
	echo "Using role $(ROLE)"; \
	change_type="CREATE"; \
	if aws cloudformation describe-stacks --region $(AWS_REGION) --stack-name $(STACK_NAME) >/dev/null 2>&1; then change_type="UPDATE"; fi; \
	aws cloudformation create-change-set \
		--region $(AWS_REGION) \
		--stack-name $(STACK_NAME) \
		--change-set-name $(CHANGE_SET) \
		--change-set-type $$change_type \
		--template-body file://$(TEMPLATE) \
		--role-arn $(ROLE) \
		--parameters $(PARAMS) \
		--capabilities CAPABILITY_NAMED_IAM; \
	aws cloudformation wait change-set-create-complete --region $(AWS_REGION) --stack-name $(STACK_NAME) --change-set-name $(CHANGE_SET); \
	aws cloudformation describe-change-set --region $(AWS_REGION) --stack-name $(STACK_NAME) --change-set-name $(CHANGE_SET)

apply:
	aws cloudformation execute-change-set --region $(AWS_REGION) --stack-name $(STACK_NAME) --change-set-name $(CHANGE_SET)
	@echo "Waiting for the stack. EKS takes ten to fifteen minutes."
	aws cloudformation wait stack-create-complete --region $(AWS_REGION) --stack-name $(STACK_NAME) 2>/dev/null || \
	aws cloudformation wait stack-update-complete --region $(AWS_REGION) --stack-name $(STACK_NAME)

kube:
	$(eval ROLE := $(DEPLOY_ROLE_ARN))
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(STACK_NAME) --role-arn $(ROLE)
	kubectl get nodes -L role,topology.kubernetes.io/zone

deploy:
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap clickhouse-config -n $(NAMESPACE) --from-file=../config/server/config.d --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap clickhouse-users -n $(NAMESPACE) --from-file=../config/server/users.d --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap keeper-config -n $(NAMESPACE) --from-file=../config/keeper --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f kubernetes/clickhouse.yaml
	kubectl rollout status statefulset/keeper -n $(NAMESPACE) --timeout=300s
	kubectl rollout status statefulset/clickhouse -n $(NAMESPACE) --timeout=300s
	kubectl get pods -n $(NAMESPACE) -o wide

schema:
	kubectl create configmap clickhouse-schema -n $(NAMESPACE) --from-file=../schema --dry-run=client -o yaml | kubectl apply -f -
	kubectl delete job apply-schema -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f kubernetes/schema-job.yaml
	kubectl wait --for=condition=complete job/apply-schema -n $(NAMESPACE) --timeout=300s
	kubectl logs job/apply-schema -n $(NAMESPACE)

test:
	@kubectl port-forward -n $(NAMESPACE) pod/clickhouse-0 18123:8123 >/dev/null 2>&1 & PF0=$$!; \
	kubectl port-forward -n $(NAMESPACE) pod/clickhouse-1 18124:8123 >/dev/null 2>&1 & PF1=$$!; \
	trap 'kill $$PF0 $$PF1 2>/dev/null' EXIT; \
	sleep 3; \
	REPLICA_0=http://localhost:18123 REPLICA_1=http://localhost:18124 ../tests/test-cluster.sh

destroy-kubernetes:
	@if kubectl get nodes >/dev/null 2>&1; then \
		kubectl delete job apply-schema -n $(NAMESPACE) --ignore-not-found; \
		kubectl delete --ignore-not-found -f kubernetes/clickhouse.yaml; \
		kubectl delete pvc --all -n $(NAMESPACE) --ignore-not-found; \
	else \
		echo "Cluster unreachable; assuming its resources are already gone."; \
	fi

destroy-stack:
	@if aws cloudformation describe-stacks --region $(AWS_REGION) --stack-name $(STACK_NAME) >/dev/null 2>&1; then \
		aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_NAME); \
		echo "Waiting for stack deletion..."; \
		aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_NAME); \
	else \
		echo "Stack $(STACK_NAME) does not exist. Skipping."; \
	fi

destroy-bootstrap:
	@if aws cloudformation describe-stacks --region $(AWS_REGION) --stack-name $(BOOTSTRAP_STACK) >/dev/null 2>&1; then \
		aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(BOOTSTRAP_STACK); \
		aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(BOOTSTRAP_STACK); \
	else \
		echo "Bootstrap stack $(BOOTSTRAP_STACK) does not exist. Skipping."; \
	fi

destroy: destroy-kubernetes destroy-stack destroy-bootstrap

.PHONY: bootstrap plan apply kube deploy schema test destroy-kubernetes destroy-stack destroy-bootstrap destroy
