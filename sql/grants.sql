-- Remove the wrongly named user created first (IAM: is for IAM users, not roles)
REVOKE ALL ON ALL TABLES IN SCHEMA gbfs FROM "IAM:arturo-gbfs-orchestrator-role";
REVOKE ALL ON SCHEMA gbfs FROM "IAM:arturo-gbfs-orchestrator-role";
DROP USER "IAM:arturo-gbfs-orchestrator-role";

-- Lambda roles connect as IAMR:<role name>
GRANT USAGE ON SCHEMA gbfs TO "IAMR:arturo-gbfs-orchestrator-role";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA gbfs TO "IAMR:arturo-gbfs-orchestrator-role";
