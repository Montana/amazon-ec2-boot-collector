#!/bin/bash

create_queue() {

    queue_url_tmp=$(aws sqs create-queue --queue-name "$1" --region sa-east-1 | jq -r .QueueUrl)

    json_policy=$(
        cat <<-END
    {
    "Policy":"{\"Version\": \"2012-10-17\",\"Id\": \"project-sqs-sns\",\"Statement\": [{\"Sid\": \"notification-policy\",\"Effect\": \"Allow\",\"Principal\": {\"AWS\": \"*\"},\"Action\": [\"sqs:SendMessage\",\"sqs:DeleteMessage\"],\"Resource\": \"arn:aws:sqs:sa-east-1:xxxxxxxxxxxxx:$1\",\"Condition\": {\"ArnLike\": {\"aws:SourceArn\": \"arn:aws:sns:sa-east-1:xxxxxxxxxxxxx:*\"}}}]}"
    }
END
    )
    echo "$json_policy" >set-queue-attributes.json

    aws sqs set-queue-attributes --queue-url "$queue_url_tmp" --region sa-east-1 --attributes file://set-queue-attributes.json

}

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve the $source until the file is no longer a symlink - montana
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $source was a relative symlink, we need to resolve it relative to the path where the symlink file was located - montana
done
DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

echo "run at $DIR"

user_queue_etl_q=$(
    cat <<-END
SELECT DISTINCT
    tu.email
    , concat('project-' , tu.identifier) AS queue_name
    , concat('arn:aws:sns:sa-east-1:xxxxxxxxxxxxx:system-notification-' , ts.account) AS topic_arn
FROM
    users.tbl_users tu
    INNER JOIN users.tbl_user_domains tud ON tud.id_user = tu.id
    INNER JOIN configurations.tbl_subdomain ts ON tud.id_domain = ts.id
WHERE
    tu.enabled = TRUE
    AND ts.enabled = TRUE
ORDER BY
    tu.email
END
)

export $(cat .env | xargs)

export PGPASSWORD=$DB_PASSWORD

psql -U $DB_USER \
    -d $DB_NAME \
    -h $DB_SERVER \
    -c "$user_queue_etl_q" \
    -qAtX >users-sns-sqs.csv

QUEUES_EXISTS_AWS=$(aws sqs --region sa-east-1 list-queues | jq -r '.QueueUrls[]' | uniq | sort)

for i in $(cat users-sns-sqs.csv | cut -d '|' -f 2 | uniq); do
    if $(grep -Fxq "https://sa-east-1.queue.amazonaws.com/xxxxxxxxxxxxx/$i" <<<"$QUEUES_EXISTS_AWS"); then
        echo "existe $i"
    else
        echo "nao existe $i"
        create_queue $i
    fi

done

echo "assign SNS to SQS"

set -e

for topic_arn in $(cat users-sns-sqs.csv | cut -d '|' -f 3 | sort | uniq); do

    HAS_SQS_ASSIGN_LIST=$(aws sns --region sa-east-1 list-subscriptions-by-topic --topic-arn $topic_arn | jq -r .Subscriptions[].Endpoint)

    if [ -z "$HAS_SQS_ASSIGN_LIST" ]; then

        for sqs_assing_user in $(cat users-sns-sqs.csv | grep "$topic_arn" | cut -d '|' -f 2 | sort | uniq); do
            aws sns --region sa-east-1 subscribe --topic-arn $topic_arn --protocol sqs \
                --notification-endpoint "arn:aws:sqs:sa-east-1:xxxxxxxxxxxxx:$sqs_assing_user"
        done

    else

        for sqs_assing_user in $(cat users-sns-sqs.csv | grep "$topic_arn" | cut -d '|' -f 2 | sort | uniq); do
            if [ -z "$(echo $HAS_SQS_ASSIGN_LIST | grep $sqs_assing_user)" ]; then
                aws sns --region sa-east-1 subscribe --topic-arn $topic_arn --protocol sqs \
                    --notification-endpoint "arn:aws:sqs:sa-east-1:xxxxxxxxxxxxx:$sqs_assing_user"
            fi

        done
    fi

done

# Can probably update the policies at some point. 
