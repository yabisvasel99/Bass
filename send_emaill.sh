#!/bin/bash

# Vérifier que le script est exécuté avec Bash
if [ -z "$BASH_VERSION" ]; then
    echo "Erreur : Ce script doit être exécuté avec Bash, pas avec sh."
    echo "Utilisez : bash $0 ou ./$0"
    exit 1
fi

# Configuration
LOG_FILE="email_log.txt"         # Fichier de logs
TIMEOUT=10                       # Timeout pour tester la connexion SMTP (en secondes)

# Listes pour la rotation des objets et noms d'expéditeur
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

# Demander le fichier SMTP à l'utilisateur
echo "Entrez le chemin du fichier contenant les SMTP (format: Smtp|port|mail|motdepasse) :"
read -r SMTP_FILE

# Vérifier si le fichier SMTP existe
if [[ ! -f "$SMTP_FILE" ]]; then
    echo "Erreur : Le fichier $SMTP_FILE n'existe pas."
    exit 1
fi

# Demander le fichier des destinataires à l'utilisateur
echo "Entrez le chemin du fichier contenant les destinataires (un email par ligne) :"
read -r RECIPIENTS_FILE

# Vérifier si le fichier des destinataires existe
if [[ ! -f "$RECIPIENTS_FILE" ]]; then
    echo "Erreur : Le fichier $RECIPIENTS_FILE n'existe pas."
    exit 1
fi

# Charger les SMTP dans un tableau
mapfile -t SMTP_LIST < <(grep -v '^$' "$SMTP_FILE")
if [[ ${#SMTP_LIST[@]} -eq 0 ]]; then
    echo "Erreur : Le fichier $SMTP_FILE est vide."
    exit 1
fi

# Charger les destinataires dans un tableau
mapfile -t RECIPIENTS < <(grep -v '^$' "$RECIPIENTS_FILE")
if [[ ${#RECIPIENTS[@]} -eq 0 ]]; then
    echo "Erreur : Le fichier $RECIPIENTS_FILE est vide."
    exit 1
fi

# Tableau pour stocker les SMTP valides
declare -a VALID_SMTPS=("${SMTP_LIST[@]}")
CURRENT_SMTP_INDEX=0
SUBJECT_INDEX=0
SENDER_INDEX=0

# Fonction pour tester la connexion SMTP
test_smtp() {
    local smtp_info="$1"
    IFS='|' read -r smtp_host smtp_port smtp_user smtp_pass <<< "$smtp_info"
    local test_cmd="curl -s --connect-timeout $TIMEOUT --max-time $TIMEOUT -u \"$smtp_user:$smtp_pass\" \"smtp://$smtp_host:$smtp_port\" --ssl-reqd"
    
    if eval "$test_cmd" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Fonction pour envoyer un email
send_email() {
    local recipient="$1"
    local smtp_info="$2"
    local subject="${SUBJECTS[$SUBJECT_INDEX]}"
    local sender_name="${SENDERS[$SENDER_INDEX]}"
    IFS='|' read -r smtp_host smtp_port smtp_user smtp_pass <<< "$smtp_info"

    # Corps de l'email (simple pour cette version)
    local body="Bonjour,\n\nCeci est un email test envoyé depuis le script Bash.\nCordialement,\n$sender_name"

    # Commande curl pour envoyer l'email
    local curl_cmd=(
        curl -s
        --connect-timeout "$TIMEOUT"
        --max-time "$TIMEOUT"
        --url "smtp://$smtp_host:$smtp_port"
        --ssl-reqd
        --mail-from "$smtp_user"
        --mail-rcpt "$recipient"
        --user "$smtp_user:$smtp_pass"
        -T <(echo -e "From: \"$sender_name\" <$smtp_user>\nTo: $recipient\nSubject: $subject\n\n$body")
    )

    # Exécuter la commande et capturer le résultat
    if "${curl_cmd[@]}" >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Email envoyé à $recipient via $smtp_host:$smtp_port (Objet: $subject, Expéditeur: $sender_name)" >> "$LOG_FILE"
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Échec de l'envoi à $recipient via $smtp_host:$smtp_port" >> "$LOG_FILE"
        return 1
    fi
}

# Boucle principale pour envoyer les emails
for recipient in "${RECIPIENTS[@]}"; do
    # Vérifier s'il reste des SMTP valides
    if [[ ${#VALID_SMTPS[@]} -eq 0 ]]; then
        echo "Erreur : Aucun SMTP valide restant."
        exit 1
    fi

    # Sélectionner le SMTP courant
    smtp_info="${VALID_SMTPS[$CURRENT_SMTP_INDEX]}"

    # Tester le SMTP
    if ! test_smtp "$smtp_info"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - SMTP $smtp_info défaillant, suppression de la liste." >> "$LOG_FILE"
        # Supprimer le SMTP défaillant
        VALID_SMTPS=("${VALID_SMTPS[@]:0:$CURRENT_SMTP_INDEX}" "${VALID_SMTPS[@]:$((CURRENT_SMTP_INDEX + 1))}")
        # Ajuster l'index si nécessaire
        if [[ $CURRENT_SMTP_INDEX -ge ${#VALID_SMTPS[@]} ]]; then
            CURRENT_SMTP_INDEX=0
        fi
        continue
    fi

    # Envoyer l'email
    if send_email "$recipient" "$smtp_info"; then
        # Passer au prochain objet et expéditeur
        SUBJECT_INDEX=$(( (SUBJECT_INDEX + 1) % ${#SUBJECTS[@]} ))
        SENDER_INDEX=$(( (SENDER_INDEX + 1) % ${#SENDERS[@]} ))
    else
        # Supprimer le SMTP défaillant après échec d'envoi
        echo "$(date '+%Y-%m-%d %H:%M:%S') - SMTP $smtp_info défaillant après tentative d'envoi, suppression." >> "$LOG_FILE"
        VALID_SMTPS=("${VALID_SMTPS[@]:0:$CURRENT_SMTP_INDEX}" "${VALID_SMTPS[@]:$((CURRENT_SMTP_INDEX + 1))}")
        if [[ ${#VALID_SMTPS[@]} -eq 0 ]]; then
            echo "Erreur : Aucun SMTP valide restant."
            exit 1
        fi
    fi

    # Passer au prochain SMTP
    CURRENT_SMTP_INDEX=$(( (CURRENT_SMTP_INDEX + 1) % ${#VALID_SMTPS[@]} ))
done

echo "Envoi des emails terminé. Consultez $LOG_FILE pour les détails."