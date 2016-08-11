About
----------
This document describes the DHCP options necessary so that you can discover Apple NetBoot sources with the option-key boot picker on a Mac client.

Some of the details will be specific to a particular environment, but the overall design is public. It took a good bit of trial and error to figure this out because:
   * There are variances and bugs in how Apple implements NetBoot on its models.
   * There are plenty of examples for DHCP NetBoot options online, but most paint an incomplete picture, only providing examples specific to one environment.  This document attempts to more completely describe what is required.
      * This is made worse by the fact that there's a very easy way to make Apple NetBoot work if you have Cisco equipment.  Simply open broadcast traffic between the clients and the NetBoot server with an IP Helper.  An IP Helper passes all traffic to the NetBoot server, so you don't have to know exactly what DHCP options are in play.
   * Some DHCP _client_ options are named similarly to _service_ options, which confuses various narratives.
   * The format of client option 43 is hex-encoded, and it's easy to make a mistake.
   * The format of client option 17 uses a colon in a place where you'd expect to put a forward slash.
   
Authors
----------
Written by Gerrit DeWitt (gdewitt@gsu.edu) using sources as noted.

Background Information
----------
Apple NetBoot provides a method to boot a Mac via the network.  It is similar to PXE booting, but not the same.

In this document, the term “NetBoot” simply refers to any network-bootable source providing OS X for Mac computers.  This includes NetInstall and NetRestore sources as well.  In fact, most will probably be using NetInstall images because the classic use case for Apple NetBoot is that it serves as alternative boot media used when re-imaging computers.  A NetInstall source is preferable to external, bootable media for some environments.

Apple NetBoot uses DHCP options to advertise and select boot information, TFTP to download a booter and pre-linked kernel, then either NFS or HTTP to obtain the &#8220;boot root&#8221; filesystem.  Key differences between it and PXE are:
   * With PXE, the “whole operating system” is downloaded into RAM via TFTP, not just the booter, kernel, and kernel cache.
   * DHCP options are much more complex for Apple NetBoot.

Thus it is technically possible to host Apple NetBoot and PXE services on the same server as long as you know what you're doing.

Simple NetBoot Example
----------
The simplest setup has clients and the NetBoot server are on the same subnet.  Apple has a support document naming a few techniques for providing NetBoot services across subnets<sup>5</sup>.  Unfortunately, the techniques are not described in sufficient detail or they are not generally tenable (for example, having one Ethernet port per subnet on the NetBoot server).

Considering the single subnet case is conceptually useful, though: You can learn how the client and server interact. There are a couple of places online with good information describing this interaction<sup>1,2</sup>.

From the firmware boot picker, the interaction is:
1. The Mac client sends a DHCP INFORM *broadcast* to the network asking for a list of bootable sources.  Along with this information, it identifies its hardware.
2. The NetBoot server responds with a unicast DHCP ACK containing a list of suitable sources, curated based on that hardware identification.
3. On the Mac client, the firmware boot picker renders a list of icons for bootable sources.  Upon selecting a source:
4. The Mac client sends another DHCP INFORM *broadcast* with its selection.
5. The NetBoot server responds with a unicast DHCP ACK with information about where (TFTP) to download the booter and prelinked kernel (kernelcache), where (NFS or HTTP) the root filesystem is located, and other details necessary to start booting.

Apple documentation refers to steps 1 and 2 as the &#8220;BSDP LIST&#8221; phase, and steps 4 and 5 as the &#8220;BSDP SELECT&#8221; step<sup>1</sup>.

At this point, it should be obvious that a Cisco IP Helper, designed to forward broadcast traffic from a network to a given IP address, would make it possible to use Apple NetBoot across subnets because the broadcasts (steps 2 and 4) would be sent, along with other broadcast traffic, unmodified, to the server.  The Apple NetBoot server filters out the noise of other broadcasts by only responding to messages that have DHCP Option 60 with the string &#8220;AAPLBSDPC&#8221; in them.<sup>1,2</sup>

Apple NetBoot DHCP Options
----------
As is apparent in the previous example, the contents of the various DHCP messages are dynamic.  DHCP Options as provided by a standard DHCP server are not typically dynamically generated, but it is possible to define them statically if you stick to some naming and path conventions for your NetBoot sources.

In this document, the things we have decided and keep consistent are:
   * The IP address of the NetBoot Server: If you're deploying the NetBoot container or otherwise using BSDPy, this is probably the case anyway.
   * The path to the NetBoot materials on the server: For example, name your production image “production.nbi,” and your test one “testing.nbi.”
      * This way, paths to the boot loader, prelinked kernel, and disk image are fixed.
   * The NetBoot image index: Again, a fixed number for the production and testing NetBoot sets will work.

The DHCP options necessary for Apple NetBoot were derived by consulting various online sources<sup>4</sup>, BlueCat support, and a copious amount of trial and error.  They are as follows:

| *Option* | *Type* | *Number* | *Purpose* | *Example Value and Notes* |
| --- | --- | --- | --- | --- |
| _dhcp-parameter-request-list_ | DHCP Client | 55 | List of DHCP options needed by the client. | string:<br>17, 43, 60, 67 |
| _vendor-class-identifier_ | DHCP Client | 60 | According to Apple's documentation<sup>1</sup>, this option differentiates the NetBoot server's response DHCP ACK from others. | string:<br> _AAPLBSDPC_ <br>The observed behavior is somewhat inconsistent in certain models:<br><ul><li>Option 60 absent: Some clients will list the NetBoot server</li><li>Option 60 present, value &#8220;AAPLBSDPC&#8221;: server considered</li><li>Option 60 present, value not &#8220;AAPLBSDPC&#8221;: server ignored</li></ul>|
| _vendor-encapsulated-options_ | DHCP Client | 43 | Holds Apple BSDP offer and response options, encoded per that specification<sup>1</sup>. | hex-encoded:<br>See Next Table |
| _Boot File Name_ | DHCP Client | 67 | Path to the bootloader when connected to the server via TFTP.  Note that this starts with the “tftp root” of the server. | string:<br> _production.nbi/i386/booter_ |
| _Root Path_ | DHCP Client | 17 | Specifically encoded &#8220;path&#8221; to the NFS or HTTP resource containing the disk image representing the OS X boot root. | string:<br> _nfs:10.1.2.3:/nfs/netboot-repo:production.nbi/NetInstall.dmg_ <br>Option 17 is defined to be a _directory_ containing boot materials.  Apple modifies this definition slightly because it uses it to point to _a file_, the boot root disk image.  Hence, there's a colon (:) used to separate the traditional &#8220;root path&#8221; (the NetBoot sharepoint) from the path to the NBI and dmg inside. <br>HTTP string example:<br> _http://10.1.2.3/production.nbi/NetInstall.dmg_|
| _Next Server_ | DHCP Service | N/A | IP address for the NetBoot server. | string:<br> _10.1.2.3_ <br>Note that the IP address of the server can also be encoded in _vendor-encapsulated-options_ as BSDP option 3 as demonstrated in the next table. |

BSDP Options Encoded in DHCP Option 43
----------
Apple's BSDP Options are encoded as a hex string per RFC 2132 and as documented by Apple<sup>1</sup>.

| *Segment in DHCP Option 43* | *BSDP Option* | *Length* | *Purpose* | *Example Value and Notes* |
| --- | --- | --- | --- | --- |
| 01:01:01 | 1<br>Message Type | 1 byte | Instructs the client to treat this message as a NetBoot advertisement (for drawing the boot picker). | 01 (List) |
| :01:01:02 | 1<br>Message Type | 1 byte | Instructs the client to treat this message as a NetBoot selection. | 02 (Select) |
| :03:04:0A:01:02:03 | 3<br>Server IP Address | 4 bytes | Appears to be optional, but represents the IP address of the server in hex. | 0A:01:02:03 (10.1.2.3) |
| :04:02:FF:FF | 4<br>Server Priority | 2 bytes | Any number between 00:00 (0) and FF:FF (65535).  Higher numbers have higher priorities. | FF:FF (65535), highest priority |
|:07:04:81:00:04:59 | 7<br>Default NetBoot Image ID | 4 bytes | Defines the image offered by default (N key booting). | 81:00:04:59<br>81:00 indicates that this is a NetInstall for OS X image<br>04:59 (1113) is the Image ID |
|:08:04:81:00:04:59 | 8<br>Selected NetBoot Image ID | 4 bytes | Instructs the client to boot from this image. | 81:00:04:59<br>81:00 indicates that this is a NetInstall for OS X image<br>04:59 (1113) is the Image ID |
|:09:10:81:00:04:59:0b:47:53:55:20:4e:65:74:42:6f:6f:74 | 9<br>List of Images | Variable<br>16 bytes in this example | This is the list of bootable sources provided to the client. | 81:00:04:59:0b:47:53:55:20:4e:65:74:42:6f:6f:74<br>81:00:04:59 defines the image type and ID (see options 7 and 8)<br>0b:47:53:55:20:4e:65:74:42:6f:6f:74 defines the name rendered in the firmware boot screen.  In this case, 0b (11) characters of text, 47:53:55:20:4e:65:74:42:6f:6f:74 (GSU NetBoot) |

In BSDP Options 7, 8, and 9, the four-byte &#8220;image ID&#8221; is encoded as follows:
   * The most significant two bytes define the image type.  Only the most significant byte is used.
      * Within the most significant byte, the most significant bit indicates whether the image is &#8220;diskless&#8221;:
         * Most Significant Bit Value 0 (0--- ----): Not diskless; use for NetBoot sets that shadow to a local hard disk.
         * Most Significant Bit Value 1 (1--- ----): Value 128 (0x80): Diskless; use for NetInstall (NetRestore) sets (which do not shadow) and NetBoot sets that shadow to AFP volumes or RAM disks.
      * All other bits of the most significant byte indicate the operating system being provided.
         * (-000 0000): Value 0: Mac OS 9
         * (-000 0001): Value 1: OS X
         * (-000 0010): Value 2: OS X Server
         * (-000 0011): Value 3: Diagnostics
         * (-000 0100 through -111 1111): Values 4 through 127 (0x7f): Not Known to Be Used
   * The least significant two bytes specify the Image ID, encoded in hex.  Values range from 0 (00:00) to 65535 (FF:FF).
   
Sources
----------
1. Apple - Open Source - NetBoot 2.0: Boot Server Discovery Protocol (BSDP): http://www.opensource.apple.com/source/bootp/bootp-170/Documentation/BSDP.doc
2. AFP548 - How to NetBoot Across Subnets: https://static.afp548.com/mactips/nbas.html
3. Aruba Networks - Airheads Community: Adonis BlueCat DHCP Option 43 for Aruba AP's: http://community.arubanetworks.com/t5/Aruba-Instant-Cloud-Wi-Fi/Adonis-BlueCat-DHCP-Option-43-for-Aruba-AP-s/td-p/55292
4. Example Configurations - DHCP Options for Apple NetBoot
   * https://bennettp123.com/2012/05/05/booting-imac-12,1-from-isc-dhcp
   * http://brandon.penglase.net/index.php?title=Getting_*nix_to_Netboot_Macs
   * http://blog.pivotal.io/labs/labs/using-deploystudio-across-subnets-a-path-not-taken
   * https://groups.google.com/forum/#!topic/macenterprise/RFAz7WV88wg
   * https://lists.isc.org/pipermail/dhcp-users/2012-June/015642.html
   * https://www.afp548.com/2006/12/20/howto-configure-gnulinux-to-provide-bsdp-netboot-services/
   * http://koti.kapsi.fi/~jvaltane/mac/netinstall.html
   * http://unflyingobject.com/blog/stories/netboot-on-freebsd/
   * https://forums.networkinfrastructure.info/general-discussion/netboot-with-a-mac-and-infoblox-as-dhcp-server/
   * http://docs.macsysadmin.se/2014/pdf/NetBoot_Deconstructed.pdf
5. Apple - OS X Server: How to use NetBoot across subnets: https://support.apple.com/en-us/HT202059
6. JAMF Nation - _bless_ Examples: https://jamfnation.jamfsoftware.com/discussion.html?id=5716
7. Apple - _bless_: https://developer.apple.com/legacy/library/documentation/Darwin/Reference/ManPages/man8/bless.8.html