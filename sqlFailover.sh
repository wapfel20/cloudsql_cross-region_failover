#!/bin/bash

#Set project variables
gcloud auth login
read -p 'Please provide Project ID for the project that your instance is located in:' project
gcloud config set project $project

#Make a temp directory and file to store the JSON output from gcloud
mkdir tempFiles
touch tempFiles/instanceDetails.json
touch tempFiles/instanceDetails-dr.json
touch tempFiles/replica1.json
touch tempFiles/replica2.json
touch tempFiles/replica3.json
touch tempFiles/replica4.json
touch tempFiles/replica5.json
touch tempFiles/primaryReplacementReplica.json

#Prompt the user for the primary instance and target failover replica
read -p 'Enter the primary Instance ID: ' primaryInstance
read -p 'Enter the Instance ID of the target replica: ' drInstance

#Pull all data from primary instance needed for scripting
echo "Pulling Data from your SQL instances..."
echo $(gcloud sql instances describe $primaryInstance --format="json") > tempFiles/instanceDetails.json
echo $(gcloud sql instances describe $drInstance --format="json") > tempFiles/instanceDetails-dr.json

#Store Primary instance variables locally
primaryRegion=$(jq '.region' tempFiles/instanceDetails.json)
primaryZone=$(jq '.gceZone' tempFiles/instanceDetails.json)
pZone=$(echo $primaryZone | sed 's/^"\(.*\)"$/\1/')
primaryName=$(jq '.name' tempFiles/instanceDetails.json)
primaryTier=$(jq '.settings.tier' tempFiles/instanceDetails.json)
primaryDataDiskSizeGb=$(jq '.settings.dataDiskSizeGb' tempFiles/instanceDetails.json)
primaryDataDiskType=$(jq '.settings.dataDiskType' tempFiles/instanceDetails.json)
maintenanceWindowDay=$(jq '.settings.maintenanceWindow.day' tempFiles/instanceDetails.json)
maintenanceWindowHour=$(jq '.settings.maintenanceWindow.hour' tempFiles/instanceDetails.json)
primaryIP=$(jq '.ipAddresses' tempFiles/instanceDetails.json)
replica1=$(jq '.replicaNames[0]' tempFiles/instanceDetails.json)
replica2=$(jq '.replicaNames[1]' tempFiles/instanceDetails.json)
replica3=$(jq '.replicaNames[2]' tempFiles/instanceDetails.json)
replica4=$(jq '.replicaNames[3]' tempFiles/instanceDetails.json)
replica5=$(jq '.replicaNames[4]' tempFiles/instanceDetails.json)
backupHours=$(jq '.settings.backupConfiguration.startTime' tempFiles/instanceDetails.json | cut -c2-3)
backupMinutes=$(jq '.settings.backupConfiguration.startTime' tempFiles/instanceDetails.json | cut -c5-6)
backupStartTime="$backupHours:$backupMinutes"

#Translate Maintenance Window Day into SUN, MON, TUE, WED, THU, FRI, SAT
if [ "$maintenanceWindowDay" = "1" ]
then
    maintenanceWindowDay="MON"
else
    if [ "$maintenanceWindowDay" = "2" ]
    then
        maintenanceWindowDay="TUE"
    else
        if [ "$maintenanceWindowDay" = "3" ]
        then
            maintenanceWindowDay="WED" 
        else
            if [ "$maintenanceWindowDay" = "4" ]
            then
                maintenanceWindowDay="THU"
            else
                if [ "$maintenanceWindowDay" = "5" ]
                then
                    maintenanceWindowDay="FRI"
                else
                    if [ "$maintenanceWindowDay" = "6" ]
                    then
                        maintenanceWindowDay="SAT"
                    else
                        if [ "$maintenanceWindowDay" = "7" ]
                        then
                            maintenanceWindowDay="SUN"
                        else
                            echo "Not a valid maintenance window variable"
                        fi
                    fi
                fi 
            fi
        fi
    fi
fi

#Store DR instance variables locally
drRegion=$(jq '.region' tempFiles/instanceDetails-dr.json)
drConnectionString=$(jq '.connectionName' tempFiles/instanceDetails-dr.json)
drIP=$(jq '.ipAddresses' tempFiles/instanceDetails-dr.json)
drName=$(jq '.name' tempFiles/instanceDetails-dr.json)
drNameNoQuotes=$(echo $drName| sed 's/^"\(.*\)"$/\1/')
primaryNameNoQuotes=$(echo $primaryName | sed 's/^"\(.*\)"$/\1/')
primaryFailoverReplica=$primaryNameNoQuotes-1

echo "Data pull complete."

#Create an array for the replicas to be stored in
replicas=()

#Check each replica variable to see if it's null and if not, add it to array
echo "Checking for replicas..."

if [ "$replica1" != "null" ]
then
    replicas+=("$replica1")
    if [ "$replica2" != "null" ]
    then
        replicas+=("$replica2")
        if [ "$replica3" != "null" ]
        then
            replicas+=("$replica3")
            if [ "$replica4" != "null" ]
            then
                replicas+=("$replica4")
                if [ "$replica5" != "null" ]
                then
                    replicas+=("$replica5")
                fi
            fi
        fi
    fi
fi

#Count the total number of replicas for deletion / reprovisioning purposes
totalReplicas="$(("${#replicas[*]}"-1))"


echo "We found $totalReplicas replicas in addition to the replica you've specified."

#Ask user to confirm the action since it is irreversable
read -p 'You are attempting to failover from $primaryInstance in $primaryRegion to $drInstance in $drRegion. This is an irreversible action, please type Yes to proceed: ' acceptance

if [ "$acceptance" = "Yes" ]
then
    #Promote the read replica in the DR region
    echo "Promoting the replica to a standalone instance..."
    gcloud sql instances promote-replica $drInstance
    echo "Instance promoted."

    #Upgrade the instance to HA and restart
    echo "The instance will be upgraded and restarted"
    gcloud sql instances patch $drInstance --availability-type REGIONAL --enable-bin-log --backup-start-time=$backupStartTime --maintenance-window-day=$maintenanceWindowDay --maintenance-window-hour=$maintenanceWindowHour

    #Give the instance matching CPU and Memory 
    #(note: I have decided not to add this step since by default, a replica recevies the same vCPU and Memory configuraiton as its master)
    #To add this step, just use $primaryTier, $primaryDataDiskSizeGb, and $primaryDataDiskType variables

    #Pass back new connection info (name and IP)
    echo "Your new connection string for your Primary Instance is $drConnectionString and your new IP Address is $drIP."
    echo "Please update your Application now to recover."
    echo "Be sure to check your monitoring dashboard at https://console.cloud.google.com/monitoring/dashboards/resourceList/cloudsql_database?_ga=2.191125034.1850381721.1584972854-846869614.1583449071"

    #Recreate replica the in primary instance location using primary name 
    echo "Replacing your old primary instance - creating a replica in $primaryZone"
    gcloud sql instances create $primaryFailoverReplica --zone=$pZone --master-instance-name=$drNameNoQuotes
    echo $(gcloud sql instances describe $primaryFailoverReplica --format="json") > tempFiles/primaryReplacementReplica.json
    primaryReplacementConnectionString=$(jq '.connectionName' tempFiles/primaryReplacementReplica.json)
    primaryReplacementIP=$(jq '.ipAddresses' tempFiles/primaryReplacementReplica.json)
    echo "Your new connection string for your replica is $primaryReplacementConnectionString and your new IP Address is $primaryReplacementIP"

    replicaZones=()

    #Build replicaZones Array and capture data
    if [ "$totalReplicas" != 0 ] 
    then 
        counter=1 
        for replica in "${replicas[@]}" 
        do 
            replica=$(echo $replica | sed 's/^"\(.*\)"$/\1/')
            if [ "$replica" != "$drInstance" ]
            then
                echo $(gcloud sql instances describe $replica --format="json") > tempFiles/replica$counter.json
                replicaZone=$(jq '.gceZone' tempFiles/replica$counter.json)
                replicaZone=$(echo $replicaZone | sed 's/^"\(.*\)"$/\1/')
                replicaZones+=("$replicaZone")
                ((counter++))
            fi
        done
    fi


    #Recreate replicas in primary location using primary name 
    #Need to loop through old replicas before they are deleted and grab their region and zone
    #Then reprovision them
    #Then pass back connectionName and IPs of each

    echo "Provisioning replicas back in your primary region."
    if [ "$totalReplicas" != 0 ]
    then
        counter=1
        for zone in "${replicaZones[@]}"
        do  
            replicaName="$drInstance-replica$counter"
            echo "Creating a replica in $zone."
            gcloud sql instances create $replicaName --zone=$zone --master-instance-name=$drNameNoQuotes
                
            echo $(gcloud sql instances describe $replicaName --format="json") > tempFiles/$replicaName.json
            replicaConnectionString=$(jq '.connectionName' tempFiles/$replicaName.json)
            replicaIP=$(jq '.connectionName' tempFiles/$replicaName.json)
            echo "Your new connection string for your replica is $replicaConnectionString and your new IP Address is $replicaIP"
            ((counter++))
        done
    else
        echo "There are no old replicas to replace"
    fi

    #Deletion Process... 

    #If there are old replicas, delete them
    if [ "$totalReplicas" != 0 ]
    then
        for replica in "${replicas[@]}"
        do 
            if [ "$replica" != "$drInstance" ]
            then
                echo "Deleting $replica"
                gcloud sql instances delete $replica
            fi
        done
    else
        echo "There are no old replicas to delete"
    fi

    #Delete the old primary.
    echo "Deleting your original primary instance"
    gcloud sql instances delete $primaryName
    echo "Legacy Primary instace deleted"
    
    #Inform that migration is complete!
    echo "You have successfully completed a failover. Be sure to check your monitoring dashboard at https://console.cloud.google.com/monitoring/dashboards/resourceList/cloudsql_database?_ga=2.191125034.1850381721.1584972854-846869614.1583449071"

    #Display summary (you migrated from x region to y region and created x replicas. Here are you connection strings...)


else
    echo "You did not confirm with a Yes. No changes have been made."
fi


