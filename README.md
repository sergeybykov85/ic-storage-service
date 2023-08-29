# IC Grant Delivery

## Preface
All 3 milestones are closely connected and it is an incremental development of the IC-based storage service (ic-ss) that should facilitate applications from the DCM ecosystem and its partner services. This storage service is intended to be extended later because of integration "frontend canisters and various flows" in the DCM Apps. The same storage service could be used for "different partner's services as well". 
So one of the intentions is to make the IC-based storage solution as an "abstract one" and suitable for "all products of the DCM ecosystem" (and other services as well). 

Here is a simple illustration of the backend canisters https://dcm-swiss-demo.s3.us-west-1.amazonaws.com/IC/IC_based_storage_for_dcm.jpg

***
## Attention:
_The share source code uses Sha256.mo library. The code of this file is not modified. Maybe a little later, the "vessel package management tool" will be applied for the project to include such libaries like sha256 as a dependency instead of file copying approach._

Chunk upload, http endpoint are not a part of the Milestone#1. It will be delivered
in the next milestone as it was declared. 
Some methods and data model were declared but will be utilized in the milestone#2.

***
# DONE:
## Milestone 1 - Extend the concept of the IMU NFT component and run the demo (Casper mainnet)

1. [Concept of the main canisters]
_Defined the concept of three canisters and relations between them : ApplicationService, Application, DataBucket._

2. [Implementation the basic methods and support of dynamic canister creation].
_Only main canister ApplicationService is deployed from dfx command line. Application canister is created by the ApplicationService canitser based on the logic. And DataBucket canister is created by Application canister according to the logic._

3. [ApplicationService canister supports model of Customer and Application] 
    * Include a customer into white list (access control)
    * Checking if the user belongs to the whitelist access
    * Restricted method to register any customer with a certain "Service Tier"
    * Getting a list of customers and a list of applications for customer
    * Method to signup as a customer to get a "Free Tier" (if user belongs to white list)
    * List of apps (for certain customer)
    * Deleting an existing app (access control)

4. [Application canister supports model of "Repository" and "Data Bucket"]
    * Registering a new repository (access control)
    * Getting a list of repositories, and the repository by id
    * Creating a new bucket on demand on the existing repository
    * Opportunity to store/delete a resource
    * Declaration of a new empty directory to proper organize the files (resources)
    * Setting a new active bucket

5. [Basic model and opperations for DataBucket canister] 
    * Differentiation of the resources into files and directories
    * Directory entity allows to group the list files due any reason
    * Directory is an optional
    * Files inside the directory should be uniq by its  names. Directory name is an uniq
    * Subdirectory is not supported now
    * Opportunity to store a file (till 2mb), delete it.
    * Opportunity to delete a directory with all files.
    * Getting the resource details by its id and getting a direcotry details by its name
    * Model of http headers  which could be modified (access control) which might be used while processing http query request


***

# TODO:
## Milestone 2 

***

# TODO:
## Milestone 3 

***

