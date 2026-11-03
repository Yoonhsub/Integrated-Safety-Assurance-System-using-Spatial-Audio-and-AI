"""Create a NEW disposable vision producer/operator in the local Auth Emulator."""
import argparse
import getpass

from local_demo import configure_environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--email", required=True)
    parser.add_argument("--role", choices=("vision_producer", "admin"), default="vision_producer")
    args = parser.parse_args()
    configure_environment()
    from app.local_emulator import validate_local_emulators
    from app.security import firebase_auth_app
    from firebase_admin import auth
    validate_local_emulators()
    password = getpass.getpass("New emulator account password (not saved): ")
    if len(password) < 8:
        parser.error("Use at least 8 characters")
    app = firebase_auth_app()
    # create_user rejects existing accounts; never overwrite their role/password.
    user = auth.create_user(email=args.email, password=password, app=app)
    try:
        auth.set_custom_user_claims(user.uid, {"mobi_role": args.role}, app=app)
    except Exception:
        auth.delete_user(user.uid, app=app)
        raise RuntimeError("Local role provisioning failed; new account removed") from None
    print(f"Created local emulator {args.role}: UID={user.uid}")


if __name__ == "__main__":
    main()
