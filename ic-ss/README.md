# IC Grant Delivery
## IC-based storage service

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
## Milestone 1

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
## Attention:
_Directory `screens` contains some illustration from the local replica. All articles, images, videos were used for the demo needs to illustrate the possible ways on how data could be organized. The screens refers to the icons for TTL, icon of the direcory and icon of the file. It is not the images. They are just html codes that are used by backend canister to give more pretty view. One more canister was introduced `SericeConfig` to store limits, some parameters, tier data, etc. This canister is not a part of the initial design, but it is good to have it here as well. Solution introduces concept of directories and files. Directory is a way to organize the files, it is an optional feature. Important remark is that files under the root may have the same names, duplicates are ok. But the file names under the directory should be uniq in names inside that directory._

# DONE:
## Milestone 2 
1. [Opportunity to upload a file large than 2 MB]
2. [Opportunity to use directories]
    * directory allows to organize the files
    * directory is an optional feature
    * nested directory is supported (but this feature could be restricted based on the customer's tier)
3. [Http endpoint to work with resources]
    * http routing to open the resource by its native id (/r/{ID})
    * http routing to download the resource by its native id (/d/{ID})
    * http routing to render "index" based on the existing resources  with a simple navigation (/i/)
4. [Basic concept of tiers to control the opportunies of the product for the customers]
5. [Time to live (TTL) support ]
    * TTL is applicable for file and directory
    * if TTL is set for the directory, then entire directory will be removed
    * period job is responsible to remove all expired files/directories
5. [Concept of expired resources]
    * chunks that were not finalized to the file during some period of time are the candidates for removal
    * files or directories marked with TTL are the candicates for removal
    * "obsolete chunks" or "TTL resources" could be removed by period job or urgently by the application owner
6. [Methods from DataBucket were propagated to the Application canister as well]
7. [Operation with resources]
    * some operations available besides the simple resource upload
    * copy an existing file (but not a directory)
    * delete existing resource (file or directory)
    * apply http headers for the existing resource
    * apply TTL for the existing file or directory
    * rename an exising file (but not a directory)
8. [Two options for scalling data buckets : disabled or auto]
    * disabled mode means that application owner can create any new bucket on demand
    * auto mode means that application service tries to create a new bucket if needed (based on the manual threadold or threshold from the configuration service)
9. [Opportunity to classify the customers between tiers] 
    * idea of the tier is a way to "give more or less" opportunities to the customers
    * differentiation between tiers could be later monetized on the application layer
    * the settings of each tier is a part of "ServiceConfig".
    * basic idea of the tier is a definition of : number of apps, number of repos, if nested directory allowed, if private repo is allowed, etc
  


***

# DONE:
## Milestone 3 
1. [Model of private repository]
    * http entry point expects the api key to return the file
    * repository owner can create different api keys and remove them on demand
2. [Simple http enpoint for the application canister for the convenience]
    * opportunity to see list of repositories
    * opportunity to see the certain repo by a direct link
    * repository has a link to active bucket (http entry point) for the convenience
3. [Corrections and improvement for the DataBucket canister] 
4. [Opportunity to control the output template for html files] 
    * default template for the .html file is configured by default
    * repository owner can apply another template for entire repo (the same value is set for all buckets of the repo)
    * template is applied only when resource is taken by http entry point and if resource ends with ".html"
    * exampple of the template : `ANY_HTML_TAGS${VALUE}ANY_HTML_TAGS`, where ${VALUE} is a reserved placeholder. User can apply any tags around the ${VALUE} according to his needs
5. [Integration of the ICS2 solution into existing application]
    * ICS2 storage integrated into DCM application (one of the versions)
    * Article (with single or multiple locales) entry could be published into IC ecosystem according to the criteria
    * DCM application displays the links to the articles published in IC platform in different places
   

***
