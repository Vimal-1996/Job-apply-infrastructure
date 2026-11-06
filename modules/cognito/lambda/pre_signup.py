import os


def handler(event, context):
    """Gate who may get an account.

    - Admin-created users (the portal's "Add user", or the console) are
      approved by that admin, so they are always allowed.
    - Every other path (self sign-up, first Google sign-in) is limited to the
      ALLOWED_EMAILS allowlist.

    Raising an exception makes Cognito reject the request.
    """
    if event["triggerSource"] == "PreSignUp_AdminCreateUser":
        return event

    allowed = {e.strip().lower() for e in os.environ["ALLOWED_EMAILS"].split(",") if e.strip()}
    email = (event["request"]["userAttributes"].get("email") or "").lower()

    if email not in allowed:
        raise Exception("Sign-up is not permitted for this email address.")

    # Google already verified the address; skip the confirmation step.
    if event["triggerSource"] == "PreSignUp_ExternalProvider":
        event["response"]["autoConfirmUser"] = True
        event["response"]["autoVerifyEmail"] = True
    return event
