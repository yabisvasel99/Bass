#!/bin/bash

# Vérifier que le script est exécuté avec Bash
if [ -z "$BASH_VERSION" ]; then
    echo "Erreur : Ce script doit être exécuté avec Bash, pas avec sh."
    echo "Utilisez : bash $0 ou ./$0"
    exit 1
fi

# Configuration par défaut
CONFIG_FILE="email_config.conf"
LOG_FILE="email_log.txt"
STATE_FILE="email_state.txt"
CREDENTIALS_FILE="credentials.enc"
REPORT_FILE="email_report.html"
TIMEOUT=10
MAX_RETRIES=3
MAX_CONCURRENT=3
MAX_ATTACHMENT_SIZE=$((10 * 1024 * 1024)) # 10 Mo
RATE_LIMIT_PAUSE=1 # Pause en secondes entre envois
SUBJECTS_FILE="subjects.txt"
SENDERS_FILE="senders.txt"
BODY_FILE="email_body.html"
SCHEDULE_INTERVAL=0 # Intervalle en secondes (0 = immédiat)
LANGUAGE="fr" # Langue par défaut

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Messages multilingues
declare -A MESSAGES=(
    ["fr_welcome"]="=== Email Sender v2.0 ==="
    ["fr_menu"]="1. Envoyer les emails\n2. Tester les SMTP\n3. Voir les logs\n4. Générer un rapport\n5. Quitter"
    ["fr_choice"]="Entrez votre choix (1-5) :"
    ["fr_invalid_choice"]="Choix invalide"
    ["fr_smtp_file"]="Entrez le chemin du fichier SMTP (format: Smtp|port|mail|motdepasse|oauth2_token) :"
    ["fr_recipients_file"]="Entrez le chemin du fichier des destinataires (un email par ligne) :"
    ["fr_log_file"]="Entrez le chemin du fichier de log (par défaut: $LOG_FILE) :"
    ["fr_attachment"]="Entrez le chemin du fichier joint (optionnel) :"
    ["fr_schedule"]="Entrez l'intervalle entre envois en secondes (0 pour immédiat) :"
    ["fr_success"]="Envoi réussi à %s via %s:%s"
    ["fr_failure"]="Échec de l'envoi à %s via %s:%s (Erreur: %s)"
    ["fr_summary"]="Envoi terminé en %d secondes\nSuccès : %d\nÉchecs : %d"
    ["en_welcome"]="=== Email Sender v2.0 ==="
    ["en_menu"]="1. Send emails\n2. Test SMTP servers\n3. View logs\n4. Generate report\n5. Exit"
    ["en_choice"]="Enter your choice (1-5) :"
    ["en_invalid_choice"]="Invalid choice"
    ["en_smtp_file"]="Enter the path to the SMTP file (format: Smtp|port|mail|password|oauth2_token) :"
    ["en_recipients_file"]="Enter the path to the recipients file (one email per line) :"
    ["en_log_file"]="Enter the path to the log file (default: $LOG_FILE) :"
    ["en_attachment"]="Enter the path to the attachment file (optional) :"
    ["en_schedule"]="Enter the interval between sends in seconds (0 for immediate) :"
    ["en_success"]="Successfully sent to %s via %s:%s"
    ["en_failure"]="Failed to send to %s via %s:%s (Error: %s)"
    ["en_summary"]="Sending completed in %d seconds\nSuccesses: %d\nFailures: %d"
)

# Listes par défaut
SUBJECTS=(
    "Offre spéciale pour vous"
    "Nouveau message important"
    "Découvrez nos services"
    "Mise à jour exclusive"
)
SENDERS=(
    "Équipe Marketing"
    "Service Client"
    "Support Technique"
    "Nouvelles Offres"
)

# Cache et métriques
declare -A SMTP_CACHE
declare -A SMTP_PERFORMANCE
SUCCESS_COUNT=0
FAIL_COUNT=0
START_TIME=$(date +%s)

# Gestion des interruptions
trap 'log_message "${RED}Interruption détectée, sauvegarde de l état...${NC}"; exit 1' SIGINT SIGTERM

# Fonction pour écrire dans les logs
log_message() {
    local key="$1"
    shift
    local message=$(printf "${MESSAGES[${LANGUAGE}_${key}]}" "$@")
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message//${smtp_pass}/[HIDDEN]}" >> "$LOG_FILE"
    echo -e "$message"
}

# Fonction pour valider une adresse email
validate_email() {
    local email="$1"
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# Fonction pour valider une ligne SMTP
validate_smtp_line() {
    local line="$1"
    [[ "$line" =~ ^[A-Za-z0-9.-]+\|[0-9]+\|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\|.+\|.+$ ]]
}

# Fonction pour chiffrer les identifiants
encrypt_credentials() {
    local file="$1"
    if [[ -f "$file" ]]; then
        openssl enc -aes-256-cbc -salt -in "$file" -out "$CREDENTIALS_FILE" -pass pass:secret
        log_message "${BLUE}Identifiants chiffrés dans $CREDENTIALS_FILE${NC}"
    fi
}

# Fonction pour déchiffrer les identifiants
decrypt_credentials() {
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        openssl enc -aes-256-cbc -d -in "$CREDENTIALS_FILE" -out /tmp/decrypted_credentials -pass pass:secret
        mapfile -t SMTP_LIST < /tmp/decrypted_credentials
        rm -f /tmp/decrypted_credentials
    fi
}

# Fonction pour afficher une barre de progression
progress_bar() {
    local current="$1"
    local total="$2"
    local width=50
    local percent=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    printf "\r${BLUE}Progression : ["
    printf "%${filled}s" | tr ' ' '#'
    printf "%${empty}s" | tr ' ' '-'
    printf "] %d%% (%d/%d)${NC}" "$percent" "$current" "$total"
}

# Fonction pour encoder un fichier en base64
encode_attachment() {
    local file="$1"
    if [[ -f "$file" && $(( $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file") )) -le $MAX_ATTACHMENT_SIZE ]]; then
        base64 "$file" | tr -d '\n'
    else
        log_message "${RED}Erreur : Fichier joint $file introuvable ou trop volumineux${NC}"
        exit 1
    fi
}

# Fonction pour tester la connexion SMTP
test_smtp() {
    local smtp_info="$1"
    IFS='|' read -r smtp_host smtp_port smtp_user smtp_pass oauth_token <<< "$smtp_info"
    local test_cmd="curl -s --connect-timeout $TIMEOUT --max-time $TIMEOUT -u \"$smtp_user:$smtp_pass\" \"smtp://$smtp_host:$smtp_port\" --ssl-reqd"
    [[ -n "$oauth_token" ]] && test_cmd="curl -s --connect-timeout $TIMEOUT --max-time $TIMEOUT --oauth2-bearer \"$oauth_token\" \"smtp://$smtp_host:$smtp_port\" --ssl-reqd"

    local start=$(date +%s)
    local output
    output=$(eval "$test_cmd" 2>&1)
    local exit_code=$?
    local duration=$(( $(date +%s) - start ))
    SMTP_PERFORMANCE[$smtp_info]=$duration

    if [[ $exit_code -eq 0 ]]; then
        SMTP_CACHE[$smtp_info]="success"
        return 0
    else
        SMTP_CACHE[$smtp_info]="fail"
        log_message "${RED}Test SMTP $smtp_host:$smtp_port échoué (Code: $exit_code, Erreur: $output)${NC}"
        return 1
    fi
}

# Fonction pour envoyer un email
send_email() {
    local recipient="$1"
    local smtp_info="$2"
    local subject="${SUBJECTS[$SUBJECT_INDEX]}"
    local sender_name="${SENDERS[$SENDER_INDEX]}"
    IFS='|' read -r smtp_host smtp_port smtp_user smtp_pass oauth_token <<< "$smtp_info"

    # Charger le corps de l'email
    local body
    if [[ -f "$BODY_FILE" ]]; then
        body=$(cat "$BODY_FILE" | sed "s/{DESTINATAIRE}/$recipient/g")
        [[ "$BODY_FILE" =~ \.html$ ]] && content_type="text/html" || content_type="text/plain"
    else
        body="Bonjour,\n\nCeci est un email test.\nCordialement,\n$sender_name"
        content_type="text/plain"
    fi

    # Préparer les en-têtes
    local headers="From: \"$sender_name\" <$smtp_user>\nTo: $recipient\nSubject: $subject\nMIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=\"boundary\""

    # Ajouter une pièce jointe
    local attachment_data=""
    if [[ -n "$ATTACHMENT" ]]; then
        local filename=$(basename "$ATTACHMENT")
        attachment_data="--boundary\nContent-Type: application/octet-stream\nContent-Transfer-Encoding: base64\nContent-Disposition: attachment; filename=\"$filename\"\n\n$(encode_attachment "$ATTACHMENT")\n--boundary--"
    fi

    # Commande curl
    local curl_cmd=(
        curl -s
        --connect-timeout "$TIMEOUT"
        --max-time "$TIMEOUT"
        --url "smtp://$smtp_host:$smtp_port"
        --ssl-reqd
        --mail-from "$smtp_user"
        --mail-rcpt "$recipient"
        --user "$smtp_user:$smtp_pass"
    )
    [[ -n "$oauth_token" ]] && curl_cmd+=("--oauth2-bearer" "$oauth_token")
    curl_cmd+=(-T <(echo -e "$headers\n\n--boundary\nContent-Type: $content_type; charset=utf-8\n\n$body\n$attachment_data"))

    local output
    output=$("${curl_cmd[@]}" 2>&1)
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_message "success" "$recipient" "$smtp_host" "$smtp_port"
        return 0
    else
        log_message "failure" "$recipient" "$smtp_host" "$smtp_port" "$output"
        return 1
    fi
}

# Fonction pour générer un rapport HTML
generate_report() {
    local elapsed=$(( $(date +%s) - START_TIME ))
    cat <<EOF > "$REPORT_FILE"
<!DOCTYPE html>
<html lang="$LANGUAGE">
<head>
    <meta charset="UTF-8">
    <title>Rapport d'Envoi d'Emails</title>
    <style>
        body { font-family: Arial, sans-serif; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        .success { color: green; } .failure { color: red; }
    </style>
</head>
<body>
    <h1>Rapport d'Envoi d'Emails</h1>
    <p><strong>Date :</strong> $(date)</p>
    <p><strong>Temps d'exécution :</strong> $elapsed secondes</p>
    <p><strong>Emails envoyés :</strong> $SUCCESS_COUNT</p>
    <p><strong>Emails échoués :</strong> $FAIL_COUNT</p>
    <h2>Détails</h2>
    <table>
        <tr><th>Destinataire</th><th>Statut</th><th>SMTP</th><th>Message</th></tr>
EOF
    while IFS= read -r line; do
        if [[ "$line" =~ Envoi\ réussi ]]; then
            echo "<tr><td>${line#*à }</td><td class=\"success\">Succès</td><td>${line#*via }</td><td>${line}</td></tr>" >> "$REPORT_FILE"
        elif [[ "$line" =~ Échec\ de\ l.envoi ]]; then
            echo "<tr><td>${line#*à }</td><td class=\"failure\">Échec</td><td>${line#*via }</td><td>${line}</td></tr>" >> "$REPORT_FILE"
        fi
    done < "$LOG_FILE"
    cat <<EOF >> "$REPORT_FILE"
    </table>
</body>
</html>
EOF
    log_message "${GREEN}Rapport généré : $REPORT_FILE${NC}"
}

# Menu interactif avec dialog
show_menu() {
    if command -v dialog &>/dev/null; then
        dialog --menu "${MESSAGES[${LANGUAGE}_welcome]}" 15 50 5 \
            1 "${MESSAGES[${LANGUAGE}_menu]%%\\n*}" \
            2 "${MESSAGES[${LANGUAGE}_menu]#*\\n}" \
            3 "${MESSAGES[${LANGUAGE}_menu]#*\\n*\\n}" \
            4 "${MESSAGES[${LANGUAGE}_menu]#*\\n*\\n*\\n}" \
            5 "${MESSAGES[${LANGUAGE}_menu]#*\\n*\\n*\\n*\\n}" 2> /tmp/choice
        choice=$(cat /tmp/choice)
        rm -f /tmp/choice
    else
        echo "${BLUE}${MESSAGES[${LANGUAGE}_welcome]}${NC}"
        printf "${MESSAGES[${LANGUAGE}_menu]}\n"
        echo "${MESSAGES[${LANGUAGE}_choice]}"
        read -r choice
    fi
}

# Charger la configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    log_message "${BLUE}Configuration chargée depuis $CONFIG_FILE${NC}"
fi

# Demander les fichiers d'entrée
show_menu
case $choice in
    1|2)
        if command -v dialog &>/dev/null; then
            dialog --inputbox "${MESSAGES[${LANGUAGE}_smtp_file]}" 8 50 "$SMTP_FILE" 2> /tmp/input
            SMTP_FILE=$(cat /tmp/input)
            dialog --inputbox "${MESSAGES[${LANGUAGE}_recipients_file]}" 8 50 "$RECIPIENTS_FILE" 2> /tmp/input
            RECIPIENTS_FILE=$(cat /tmp/input)
            dialog --inputbox "${MESSAGES[${LANGUAGE}_log_file]}" 8 50 "$LOG_FILE" 2> /tmp/input
            LOG_FILE=$(cat /tmp/input)
            dialog --inputbox "${MESSAGES[${LANGUAGE}_attachment]}" 8 50 "$ATTACHMENT" 2> /tmp/input
            ATTACHMENT=$(cat /tmp/input)
            dialog --inputbox "${MESSAGES[${LANGUAGE}_schedule]}" 8 50 "$SCHEDULE_INTERVAL" 2> /tmp/input
            SCHEDULE_INTERVAL=$(cat /tmp/input)
            rm -f /tmp/input
        else
            echo "${MESSAGES[${LANGUAGE}_smtp_file]}"
            read -r SMTP_FILE
            echo "${MESSAGES[${LANGUAGE}_recipients_file]}"
            read -r RECIPIENTS_FILE
            echo "${MESSAGES[${LANGUAGE}_log_file]}"
            read -r input_log
            [[ -n "$input_log" ]] && LOG_FILE="$input_log"
            echo "${MESSAGES[${LANGUAGE}_attachment]}"
            read -r ATTACHMENT
            echo "${MESSAGES[${LANGUAGE}_schedule]}"
            read -r SCHEDULE_INTERVAL
        fi

        # Valider les fichiers
        if [[ ! -f "$SMTP_FILE" ]]; then
            log_message "${RED}Erreur : Le fichier $SMTP_FILE n'existe pas${NC}"
            exit 1
        fi
        mapfile -t SMTP_LIST < <(grep -v '^$' "$SMTP_FILE")
        if [[ ${#SMTP_LIST[@]} -eq 0 ]]; then
            log_message "${RED}Erreur : Le fichier $SMTP_FILE est vide${NC}"
            exit 1
        fi
        for line in "${SMTP_LIST[@]}"; do
            if ! validate_smtp_line "$line"; then
                log_message "${RED}Erreur : Ligne SMTP invalide dans $SMTP_FILE : $line${NC}"
                exit 1
            fi
        done

        if [[ ! -f "$RECIPIENTS_FILE" ]]; then
            log_message "${RED}Erreur : Le fichier $RECIPIENTS_FILE n'existe pas${NC}"
            exit 1
        fi
        mapfile -t RECIPIENTS < <(grep -v '^$' "$RECIPIENTS_FILE")
        if [[ ${#RECIPIENTS[@]} -eq 0 ]]; then
            log_message "${RED}Erreur : Le fichier $RECIPIENTS_FILE est vide${NC}"
            exit 1
        fi
        for email in "${RECIPIENTS[@]}"; do
            if ! validate_email "$email"; then
                log_message "${RED}Erreur : Adresse email invalide dans $RECIPIENTS_FILE : $email${NC}"
                exit 1
            fi
        done

        # Chiffrer les identifiants
        encrypt_credentials "$SMTP_FILE"
        decrypt_credentials
        ;;
esac

# Charger les fichiers optionnels
[[ -f "$SUBJECTS_FILE" ]] && mapfile -t SUBJECTS < <(grep -v '^$' "$SUBJECTS_FILE")
[[ ${#SUBJECTS[@]} -eq 0 ]] && log_message "${YELLOW}Avertissement : Aucun sujet valide, utilisation des sujets par défaut${NC}"
[[ -f "$SENDERS_FILE" ]] && mapfile -t SENDERS < <(grep -v '^$' "$SENDERS_FILE")
[[ ${#SENDERS[@]} -eq 0 ]] && log_message "${YELLOW}Avertissement : Aucun expéditeur valide, utilisation des expéditeurs par défaut${NC}"

# Initialisation
declare -a VALID_SMTPS=("${SMTP_LIST[@]}")
CURRENT_SMTP_INDEX=0
SUBJECT_INDEX=0
SENDER_INDEX=0

# Boucle principale
while true; do
    show_menu
    case $choice in
        1)
            load_state() {
                if [[ -f "$STATE_FILE" ]]; then
                    mapfile -t sent_recipients < "$STATE_FILE"
                    log_message "${BLUE}État chargé : ${#sent_recipients[@]} destinataires déjà envoyés${NC}"
                fi
            }
            save_state() {
                local recipient="$1"
                echo "$recipient" >> "$STATE_FILE"
            }

            load_state
            total_recipients=${#RECIPIENTS[@]}
            current_recipient=1
            active_jobs=0

            for recipient in "${RECIPIENTS[@]}"; do
                if [[ " ${sent_recipients[*]} " =~ " $recipient " ]]; then
                    ((current_recipient++))
                    continue
                fi

                while [[ $active_jobs -ge $MAX_CONCURRENT ]]; do
                    wait -n
                    ((active_jobs--))
                done

                (
                    local sent=false
                    local attempt=0
                    while [[ "$sent" == false && $attempt -lt $MAX_RETRIES && ${#VALID_SMTPS[@]} -gt 0 ]]; do
                        # Trier les SMTP par performance
                        readarray -t VALID_SMTPS < <(for smtp in "${VALID_SMTPS[@]}"; do
                            echo "${SMTP_PERFORMANCE[$smtp]:-9999} $smtp"
                        done | sort -n | cut -d' ' -f2-)

                        smtp_info="${VALID_SMTPS[$CURRENT_SMTP_INDEX]}"
                        ((attempt++))

                        if [[ -n "${SMTP_CACHE[$smtp_info]}" && "${SMTP_CACHE[$smtp_info]}" == "fail" ]]; then
                            VALID_SMTPS=("${VALID_SMTPS[@]:0:$CURRENT_SMTP_INDEX}" "${VALID_SMTPS[@]:$((CURRENT_SMTP_INDEX + 1))}")
                            [[ $CURRENT_SMTP_INDEX -ge ${#VALID_SMTPS[@]} ]] && CURRENT_SMTP_INDEX=0
                            continue
                        fi

                        if ! test_smtp "$smtp_info"; then
                            VALID_SMTPS=("${VALID_SMTPS[@]:0:$CURRENT_SMTP_INDEX}" "${VALID_SMTPS[@]:$((CURRENT_SMTP_INDEX + 1))}")
                            [[ $CURRENT_SMTP_INDEX -ge ${#VALID_SMTPS[@]} ]] && CURRENT_SMTP_INDEX=0
                            continue
                        fi

                        if send_email "$recipient" "$smtp_info"; then
                            sent=true
                            save_state "$recipient"
                            ((SUCCESS_COUNT++))
                            SUBJECT_INDEX=$(( (SUBJECT_INDEX + 1) % ${#SUBJECTS[@]} ))
                            SENDER_INDEX=$(( (SENDER_INDEX + 1) % ${#SENDERS[@]} ))
                        else
                            SMTP_CACHE[$smtp_info]="fail"
                            VALID_SMTPS=("${VALID_SMTPS[@]:0:$CURRENT_SMTP_INDEX}" "${VALID_SMTPS[@]:$((CURRENT_SMTP_INDEX + 1))}")
                            [[ ${#VALID_SMTPS[@]} -eq 0 ]] && break
                        fi

                        CURRENT_SMTP_INDEX=$(( (CURRENT_SMTP_INDEX + 1) % ${#VALID_SMTPS[@]} ))
                        sleep "$RATE_LIMIT_PAUSE"
                    done

                    if [[ "$sent" == false ]]; then
                        log_message "${RED}Échec définitif pour $recipient après $attempt tentatives${NC}"
                        ((FAIL_COUNT++))
                    fi

                    progress_bar $current_recipient $total_recipients
                    [[ $SCHEDULE_INTERVAL -gt 0 ]] && sleep "$SCHEDULE_INTERVAL"
                ) &

                ((active_jobs++))
                ((current_recipient++))
            done

            wait
            END_TIME=$(date +%s)
            ELAPSED=$((END_TIME - START_TIME))
            log_message "summary" "$ELAPSED" "$SUCCESS_COUNT" "$FAIL_COUNT"
            ;;
        2)
            log_message "${BLUE}Test des SMTP :${NC}"
            for smtp_info in "${SMTP_LIST[@]}"; do
                if test_smtp "$smtp_info"; then
                    log_message "${GREEN}SMTP $smtp_info fonctionnel${NC}"
                else
                    log_message "${RED}SMTP $smtp_info défaillant${NC}"
                fi
            done
            ;;
        3)
            if [[ -f "$LOG_FILE" ]]; then
                less "$LOG_FILE"
            else
                log_message "${YELLOW}Aucun log disponible${NC}"
            fi
            ;;
        4)
            generate_report
            ;;
 * 5)
            log_message "${BLUE}Sortie du programme${NC}"
            exit 0
            ;;
        *)
            log_message "invalid_choice"
            ;;
    esac
done