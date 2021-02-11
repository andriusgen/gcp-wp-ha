# gcp-wp-ha 
This Repository Contains Terraform Code to Deploy WordPress on GCP Infrastructure

# Usage
First Download or Clone this repo to your local system
After this, 
To Initiate Terraform WorkSpace :- terraform init
To create infrastructure, run command :- terraform apply -auto-approve
To delete infrastructure, run command :- terraform destroy -auto-approve

# Prerequisites
Terraform should be Installed
gcloud SDK should be Installed
Replace the gcpCreds.json file with Yours Service Account Key file
In variables.tf Replace the Project ID with Yours
