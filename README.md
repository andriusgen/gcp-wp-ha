# gcp-wp-ha 
This Repository Contains Terraform Code to Deploy WordPress on GCP Infrastructure

# Usage
1. First Download or Clone this repo to your local system
2. After this, to Initiate Terraform WorkSpace :- terraform init
3. To create infrastructure, run command :- terraform apply -auto-approve
4. To delete infrastructure, run command :- terraform destroy -auto-approve

# Prerequisites
* Terraform should be Installed
* gcloud SDK should be Installed
* Replace the gcpCreds.json file with Yours Service Account Key file
* In variables.tf Replace the Project ID with Yours
