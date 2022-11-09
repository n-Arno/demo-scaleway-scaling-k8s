demo-scaleway-scaling-k8s
=========================

This demo will deploy via Terraform a Kapsule cluster along with a deployment and associated HPA (Horizontal Pod Autoscaler).

Once run, a `kubeconfig.yaml` file is created to access the cluster (`export KUBECONFIG=./kubeconfig.yaml`).

Check the number of pods of deployment `test` in namespace `default` and number of nodes.

Then run `kubectl apply -f load.yaml` to start a simulated load on the deployment. The number of pods in the deployment will go up (up to 5-6) and only 4 can be scheduled on the single node of the cluster. 

The cluster autoscaler will automatically provide a new node in the pool to accomodate the needed extra pods.

Note on the Terraform manifest
------------------------------

It demonstrate how to create a Kapsule cluster using Terraform Scaleway provider and make use of a `null_resource` to create the `kubeconfig.yaml` file and fill the information in the Terraform Kubernetes provider.

The `time_sleep` resource is used to make sure the cluster has stabilized after deployment before creating resources.
