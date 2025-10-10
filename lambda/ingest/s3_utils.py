from urllib.parse import unquote_plus

def get_object_bytes(s3, bucket, key):
    key = unquote_plus(key)
    obj = s3.get_object(Bucket=bucket, Key=key)
    return obj["Body"].read()