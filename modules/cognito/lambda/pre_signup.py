import os


def handler(event, context):
    """Allow only pre-approved emails to sign up (single-user app).

    Runs for every sign-up path (admin-created, self sign-up, Google).
    Raising an exception makes Cognito reject the request.
    """
    allowed = {e.strip().lower() for e in os.environ["ALLOWED_EMAILS"].split(",") if e.strip()}
    email = (event["request"]["userAttributes"].get("email") or "").lower()

    if email not in allowed:
        raise Exception("Sign-up is not permitted for this email address.")

    # Google already verified the address; skip the confirmation step.
    if event["triggerSource"] == "PreSignUp_ExternalProvider":
        event["response"]["autoConfirmUser"] = True
        event["response"]["autoVerifyEmail"] = True
    return event
