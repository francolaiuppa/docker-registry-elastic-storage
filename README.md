# Private Docker Registry with Elastic Block Storage
This repo provisions a Digital Ocean Droplet with Docker Machine, then creates and attaches an Elastic Block Storage to the droplet, configuring Docker to use it.
It also provides a web frontend to see the repositories and images that the registry has.

For more info please see the [blog post](http://francolaiuppa.com).

# How to use it?
Fill the `DIGITALOCEAN_ACCESS_TOKEN` var in default.env, then
`./setup.sh` and wait!.

# TODO
- SSL (letsencrypt.org)
- Authentication for pushing to repo using .htpasswd files
- Reuse same .htpasswd for Frontend (maybe proxy through nginx?)
- Make it less verbose
