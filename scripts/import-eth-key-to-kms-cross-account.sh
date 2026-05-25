# Run from the AWS account that hosts the aws_kms_external_key.
# Pulls an Ethereum private key cross-account from Secrets Manager
# (using a separate set of credentials for the source account),
# converts it to PKCS#8 DER, imports it as key material into the
# local KMS key (ECC_SECG_P256K1 / SIGN_VERIFY), and prints the
# resulting KMS public key.
#
# Required env vars:
#   SOURCE_SECRET_NAME             - name or ARN of the Secrets Manager secret
#                                    in the source account (SecretString = 0x-hex
#                                    or 64 bare hex chars)
#   SOURCE_REGION                  - region of the source secret
#   SOURCE_AWS_ACCESS_KEY_ID       - credentials for the source (Secrets Manager)
#   SOURCE_AWS_SECRET_ACCESS_KEY   - account; used only for the get-secret-value
#   SOURCE_AWS_SESSION_TOKEN       - call (optional, only if using STS)
#   KMS_KEY_ID                     - id or ARN of the local external KMS key
#                                    (must be in PendingImport state)
#
# Optional:
#   KMS_REGION                     - region of the KMS key; defaults to
#                                    AWS_REGION / AWS_DEFAULT_REGION
#
# Native AWS_* env (or default profile) must point at the KMS account.

set -e
set -u

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Required variables
: "${SOURCE_SECRET_NAME:?SOURCE_SECRET_NAME must be set}"
: "${SOURCE_REGION:?SOURCE_REGION must be set}"
: "${SOURCE_AWS_ACCESS_KEY_ID:?SOURCE_AWS_ACCESS_KEY_ID must be set (source account)}"
: "${SOURCE_AWS_SECRET_ACCESS_KEY:?SOURCE_AWS_SECRET_ACCESS_KEY must be set (source account)}"
: "${KMS_KEY_ID:?KMS_KEY_ID must be set}"

# KMS region: explicit, then AWS_REGION, then AWS_DEFAULT_REGION
KMS_REGION="${KMS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
if [ -z "$KMS_REGION" ]; then
    print_error "KMS_REGION (or AWS_REGION / AWS_DEFAULT_REGION) must be set"
    exit 1
fi

# Step 1: Download private key from Secrets Manager in the source account.
# Credentials are applied inline so they only affect this one aws call.
# The script's native AWS_* env is never mutated.

download_private_key() {
    print_status "Step 1: Downloading private key cross-account from Secrets Manager ($SOURCE_SECRET_NAME in $SOURCE_REGION)..."

    SECRET_JSON=$(
        AWS_ACCESS_KEY_ID="$SOURCE_AWS_ACCESS_KEY_ID" \
        AWS_SECRET_ACCESS_KEY="$SOURCE_AWS_SECRET_ACCESS_KEY" \
        AWS_SESSION_TOKEN="${SOURCE_AWS_SESSION_TOKEN:-}" \
        AWS_REGION="$SOURCE_REGION" \
        aws secretsmanager get-secret-value \
            --secret-id "$SOURCE_SECRET_NAME" \
            --query 'SecretString' \
            --output text
    )

    if [ -z "$SECRET_JSON" ]; then
        print_error "Failed to retrieve secret value"
        exit 1
    fi  

    if ! PRIVATE_KEY=$(echo "$SECRET_JSON" | jq -er '.["wallet.private_key"]'); then
        print_error "SecretString does not contain .wallet.private_key"
        print_error "Available leaf paths in the secret:"
        echo "$SECRET_JSON" | jq -r 'paths(scalars) | join(".")' >&2
        exit 1
    fi
 
    echo "$PRIVATE_KEY" > kms-connector-wallet.key
    print_status "Private key retrieved"
}

# Step 2: Convert to PKCS#8 DER (secp256k1) for KMS import.
format_for_kms() {
    print_status "Step 2: Converting private key to PKCS#8 DER..."

    HEX=$(tr -d '\n\r \t' < kms-connector-wallet.key | sed 's/^0x//')
    if [ "${#HEX}" -ne 64 ]; then
        print_error "Expected 64-char hex private key, got ${#HEX} chars"
        exit 1
    fi

    printf '302e0201010420%sa00706052b8104000a' "$HEX" \
        | xxd -r -p \
        | openssl ec -inform DER -out private-key.pem 2>/dev/null

    openssl pkcs8 -topk8 -outform der -nocrypt \
        -in private-key.pem \
        -out private-key.der

    print_status "Conversion complete"
}

# Step 3: Import the key material into the local KMS external key.
import_to_kms() {
    print_status "Step 3: Importing key material into KMS ($KMS_KEY_ID in $KMS_REGION)..."

    KEY_STATE=$(
        aws kms describe-key \
            --region "$KMS_REGION" \
            --key-id "$KMS_KEY_ID" \
            --query 'KeyMetadata.KeyState' \
            --output text
    )

    if [ "$KEY_STATE" != "PendingImport" ]; then
        print_error "KMS key state is '$KEY_STATE'; expected 'PendingImport'"
        exit 1
    fi

    aws kms get-parameters-for-import \
        --region "$KMS_REGION" \
        --key-id "$KMS_KEY_ID" \
        --wrapping-algorithm RSAES_OAEP_SHA_256 \
        --wrapping-key-spec RSA_4096 \
        > key-import-params.json

    jq -r '.PublicKey' key-import-params.json | base64 -d > WrappingPublicKey.bin
    jq -r '.ImportToken' key-import-params.json | base64 -d > ImportToken.bin

    openssl pkeyutl -encrypt \
        -in private-key.der \
        -inkey WrappingPublicKey.bin \
        -keyform DER \
        -pubin \
        -pkeyopt rsa_padding_mode:oaep \
        -pkeyopt rsa_oaep_md:sha256 \
        -out EncryptedKeyMaterial.bin

    aws kms import-key-material \
        --region "$KMS_REGION" \
        --key-id "$KMS_KEY_ID" \
        --encrypted-key-material fileb://EncryptedKeyMaterial.bin \
        --import-token fileb://ImportToken.bin \
        --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE

    print_status "Key material imported"
}

# Step 4: Fetch and print the KMS public key.
print_kms_public_key() {
    print_status "Step 4: Fetching public key from KMS..."

    aws kms get-public-key \
        --region "$KMS_REGION" \
        --key-id "$KMS_KEY_ID" \
        --query 'PublicKey' \
        --output text \
        | base64 -d > kms-public-key.der

    print_status "KMS public key (PEM):"
    echo ""
    openssl pkey -pubin -inform DER -in kms-public-key.der -outform PEM
    echo ""

    if command -v cast >/dev/null 2>&1; then
        ETH_ADDR=$(
            AWS_KMS_KEY_ID="$KMS_KEY_ID" \
            AWS_REGION="$KMS_REGION" \
            cast wallet address --aws 2>/dev/null || true
        )
        if [ -n "$ETH_ADDR" ]; then
            print_status "Derived Ethereum address: $ETH_ADDR"
        fi
    else
        print_warning "cast not installed; skipping Ethereum address derivation"
    fi
}

# Cleanup on exit (success or failure) so private material never lingers.
cleanup() {
    print_status "Cleaning up local key material..."
    rm -f \
        kms-connector-wallet.key \
        private-key.pem \
        private-key.der \
        key-import-params.json \
        WrappingPublicKey.bin \
        ImportToken.bin \
        EncryptedKeyMaterial.bin \
        kms-public-key.der
    print_status "Local files removed"
}

trap cleanup EXIT

main() {
    print_status "Starting Ethereum key import to KMS (cross-account secret pull)"
    echo ""

    download_private_key
    format_for_kms
    import_to_kms
    print_kms_public_key

    echo ""
    print_status "==================================="
    print_status "Import completed successfully!"
    print_status "==================================="
}

main "$@"