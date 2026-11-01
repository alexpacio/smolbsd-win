to implement:

- a way to create new root images with declarative approach to include packages (apps and libraries) and custom scripts. See smolBSD and take inspiration from it
- ability for nitro to start more than one app and ability for the hadron service toml definition file to define more than a single app
- guest applications use C++, Go and Rust only. Keep the shared C transport as an internal library, with Boost.Asio, goroutine and Tokio adapters. Use native Fory xlang models for typed user-defined objects shared with the host. C, D and Node application targets and their custom codec/runtime layers have been removed in the Hadron repositories.
- implement env var passing and secret passing to the guest program(s)
- implement namespacing for isolation of set of services. The host side should be isolating access to data as well across namespaces
- implement host side rate limiting and anti DDoS over virtio serial
- implement hadron service resource quotas and QoS fairness policies
- speed up netbsd network bring up by disabling dhcpv6 or ipv6 and using static ip addresses orchestrated by the hadron daemon. choose the best way to obtain fastest boot time to network availability
- make sure it is easy for the user/developer to figure out how to use dynamic libraries in netbsd userspace from their programs
- thoroughly document how can we retrieve and compile the netbsd images, source code etc. How can we run the entire dev toolkit and build pipeline in Hadron in an air-gapped environment.


---

STEP 2


- Try to get rid of docker and directly use smolbsd microvms for builds. Hadron should be Docker-free
- Implement virtio-9p folder redirection in order to directly pass the things you might need to pass, including program binaries that nitro shall execute in the local sandbox development stage to avoid rebuilding the qcow2 images all the time. They are supposed to be used only in production
- Document the way a developer should use this via visual studio code or shell, how he could develop a new program and how it gets this working using the entire toolchain
- Create an MCP server to allow LLMs agents to easily interact with this to ship scaled applications and create straight-forward LLM wikis for them in C:\Users\alexpacio\git\netter\hadron-docs
- Evaluate the use of VHDX as image format in windows if it helps when coupled with ReFS for performances and disk space usage by any mean. Evaluate performance penalty under QEMU
