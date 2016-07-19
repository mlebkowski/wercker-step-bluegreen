# Perform a blue/green deployment on Docker Cloud

## Usage

```
deploy:
    steps:
        - mlebkowski/bluegreen:
            user: $DOCKERCLOUD_USER
            pass: $DOCKERCLOUD_PASS
            load_balancer_name: haproxy
			backend_names: ""
            minimum_scale: 1
            rollback: false
            action_timeout: 45
```

## Configuration

 * `user` is your dockercloud username
 * `pass` is your password or better yet an API key
 * `load_balancer_name` should match the service name of your load balancer
 * `backend_names` - instead of defining the backends on a load balancer, add them here (less flexible). This should be a space separated list of blue/green backend service names.
 * `minimum_scale` - scale up to at least this much containers after deployment. Set to `0` to disable scaling after deployment
 * `rollback` - you may use this to rollback to previous backend, skipping the "redeploy" step
 * `action_timeout` is time limit in seconds to wait for actions such as redeploy to complete

## Other setup

1. Prepare your stack with two different backend services. They will be switched back and forth. 
2. Add a load balancer (is suggest using dockercloud/haproxy)
3. Define a "BLUEGREEN_SERVICE_NAMES" env on the load balancer and place all of the available backend service names space separated. You can overwrite this with "backend_names" parameter in the wercker step.

More about blue/green: https://blog.tutum.co/2015/06/08/blue-green-deployment-using-containers/

Scaling is not available for services using `EVERY_NODE` deployment strategy. Make sure all your backends either use it or not.
