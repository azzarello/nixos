# Baseline shared by every host: the admin user, key-only SSH, locale, nix settings.
{ ... }:
{
  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";

  users.users.corndog = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOuPPXrbNYSI9VidTM20hFZOhL/4SklO++MjNbh0WpsZ corndog@mac"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "@wheel" ];
    # a hung cache download once stalled a rebuild for 10+ min; fail fast and retry instead
    connect-timeout = 10;
    stalled-download-timeout = 60;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}
