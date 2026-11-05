# About Calisto

Calisto is built and maintained by Abhijit Ghosh in Australia.

It started from a practical problem. ASD's Essentials asks agencies to rate every action in every
domain it applies to, cite their evidence and keep the result for later review. Much of that
evidence already sits in Azure, Microsoft 365 and AWS, but collecting it by hand takes weeks.
Calisto reads it for the agency, proposes what the evidence shows, and leaves every conclusion
to the agency's own assessor.

## How it is built

- **Runs in the agency's tenancy.** Calisto is installed in the agency's own Azure subscription.
  Its data stays there, in an Australian region, and nothing is sent back to us.
- **Read only.** It holds read permissions only and changes nothing in the environments it
  assesses.
- **Follows ASD's material.** It ships ASD's OSCAL release unchanged and follows ASD's assessment
  process and evidence guides.
- **Open to audit.** Agencies and their assessors are welcome to [audit the code](AUDIT.md).

Calisto is free to use for Azure and Microsoft 365. AWS assessment is free while it is a preview
and will be a paid option once it is fully supported.

Calisto is independent. It is not endorsed by, affiliated with, or produced on behalf of the
Australian Signals Directorate.

## Contact

Questions, feedback, requests to audit the code, or help with an install:
[contact@calisto.run](mailto:contact@calisto.run).
