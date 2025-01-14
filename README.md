# Introduction 
This is a small project about writing a pipeline to deploy 2 storage accounts and a VM.
togther wil running a job to create and copy 100 blobs from 1 storage account to another.
a dashboard file is also attached.

# Getting Started
All code was run using a local agent defined under the name Default

Set-UP:

1. Create an Agent, be it local or hosted and connect it to the subscritption

2. Add a variable as a secret, under the name of adminpassword - this might be diffrent on other devtools, not creating a var might cause the pipeline to crash.

3. The deployment should pass now, using the azure-pipeline.yml, this is the pipeline that will use the 2 ARM templates for the VM and storage accounts. (they should already be on the subscritption)

4. Make sure the agent has all the needed rights, the scripts are run through it

5. CreateAndCopyBlobs.yml pipeline is used to create and copy the blobs, it is broken to 2 seperate jobs and should run without issues standalone.

6. The dashboard should exist and function under the name UpdatedDashboard, if it doesn't ive attached the file to import it.

Other than that, I belive this is all.

you would need to update the details of your agent, Mine was saved under the Default. 

pool:
    name: "yournamehere"


