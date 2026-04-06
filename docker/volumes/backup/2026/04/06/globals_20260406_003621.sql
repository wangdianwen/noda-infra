--
-- PostgreSQL database cluster dump
--

\restrict BbHz0aDLLkNQJ6u3dq2YS2qbXvQDsfclwHfGkNcx1uVMSdklk8R4RrdZeuc90Jh

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

--
-- Roles
--

CREATE ROLE postgres;
ALTER ROLE postgres WITH SUPERUSER INHERIT CREATEROLE CREATEDB LOGIN REPLICATION BYPASSRLS PASSWORD 'SCRAM-SHA-256$4096:ceS+iXl2rcGZczoN8i2YjQ==$XaRB21hucz2iCe4shs7ywDA8pjDswsVhQ7V9iopTusg=:C3ruZmbMhkk7m9ZCRi9Ezkryzh5/rSGZWgFfYlj0YTM=';

--
-- User Configurations
--








\unrestrict BbHz0aDLLkNQJ6u3dq2YS2qbXvQDsfclwHfGkNcx1uVMSdklk8R4RrdZeuc90Jh

--
-- PostgreSQL database cluster dump complete
--

