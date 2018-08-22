DROP TABLE IF EXISTS bindings;
DROP TABLE IF EXISTS attrs;
DROP TABLE IF EXISTS leasings;
DROP TABLE IF EXISTS docs;
DROP TABLE IF EXISTS items;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
   id SERIAL PRIMARY KEY,
   name TEXT NOT NULL,
   password TEXT NOT NULL,
   creator INTEGER,
   ctime TIMESTAMP WITH TIME ZONE DEFAULT now(),
   admin BOOLEAN NOT NULL
);

CREATE TABLE docs
(
  id SERIAL PRIMARY KEY,
  creator INTEGER NOT NULL
);

CREATE TABLE leasings (
  lessee INTEGER REFERENCES users(id),
  doc_id INTEGER REFERENCES docs(id)
);

CREATE TABLE items
(
  id SERIAL PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE attrs
(
  id SERIAL PRIMARY KEY,
  holder INTEGER NOT NULL REFERENCES docs (id),
  name TEXT NOT NULL,
  container BOOLEAN NOT NULL,
  link BOOLEAN NOT NULL
);

CREATE TABLE bindings
(
  seqnum BIGSERIAL PRIMARY KEY,
  attr_id INTEGER REFERENCES attrs(id),
  btime TIMESTAMP NOT NULL DEFAULT now(),
  item_id INTEGER REFERENCES items(id),
  doc_id INTEGER REFERENCES docs(id),
  operation SMALLINT NOT NULL -- 0 set, 1 reset, 2 insert, 3 remove
);

DROP FUNCTION IF EXISTS create_user(TEXT, TEXT, BOOLEAN, INT, TEXT);
DROP FUNCTION IF EXISTS create_first_user(TEXT);
DROP FUNCTION IF EXISTS uid(TEXT);
DROP FUNCTION IF EXISTS credentials(INTEGER, TEXT, BOOLEAN);
DROP FUNCTION IF EXISTS permission(INTEGER, TEXT, INTEGER);
DROP FUNCTION IF EXISTS user_name(INT);
DROP FUNCTION IF EXISTS lease(INT, INT, TEXT, INT);
DROP FUNCTION IF EXISTS remove_lease(INT, INT, TEXT, INT);
DROP FUNCTION IF EXISTS create_doc (INTEGER, TEXT);
DROP FUNCTION IF EXISTS remove_doc(INTEGER, INTEGER, TEXT);
DROP FUNCTION IF EXISTS set_attr(INTEGER, TEXT, TEXT, BOOLEAN, INTEGER, TEXT);
DROP FUNCTION IF EXISTS reset_attr(INTEGER, TEXT, INTEGER, TEXT);
DROP FUNCTION IF EXISTS remove_attr(INTEGER, TEXT, TEXT, INTEGER, TEXT);
DROP FUNCTION IF EXISTS insert_attr(INTEGER, TEXT, TEXT, BOOLEAN, INTEGER, TEXT);
DROP FUNCTION IF EXISTS list_docs(INTEGER, TEXT);
DROP FUNCTION IF EXISTS list_lessees(INTEGER, INTEGER, TEXT);
DROP FUNCTION IF EXISTS scandocs (INTEGER, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS isAdmin(usr INTEGER);
DROP FUNCTION IF EXISTS isCreator(doc INTEGER, usr INTEGER);
DROP FUNCTION IF EXISTS list_users(usr INTEGER, passwd TEXT);
DROP FUNCTION IF EXISTS list_all_docs(usr INTEGER, passwd TEXT);
DROP FUNCTION IF EXISTS get_scheme_id (doc INTEGER, usr INTEGER, passwd TEXT);
DROP FUNCTION IF EXISTS get_name (doc INTEGER, usr INTEGER, passwd TEXT);
DROP FUNCTION IF EXISTS has_shadow (doc INTEGER, usr INTEGER, passwd TEXT);

-- Function for creating a user
CREATE FUNCTION create_user(name TEXT, passwd TEXT, admin BOOLEAN, creator INT, creatorPassword TEXT) 
	RETURNS integer
AS $$
	DECLARE
		uid INT;
	BEGIN
   		-- Creator credentials check
    	PERFORM credentials(creator, creatorPassword, true);
		-- User insertion into database
    	INSERT INTO users (name, password, creator, admin) 
        	VALUES (name, md5(name||passwd), creator, admin) RETURNING id INTO uid;
    	RETURN uid;          
   END       
$$ LANGUAGE plpgsql;

-- Function for creating first user - same as function above, but without credential check
CREATE FUNCTION create_first_user(password TEXT) 
	RETURNS integer
AS $$
 	-- User insertion into database
	INSERT INTO users (name, password, creator, admin) 
    	VALUES ('admin', md5('admin'||password), -1, true) RETURNING id;
$$ LANGUAGE SQL;

-- Function for obtaining user ID
CREATE FUNCTION uid(usr TEXT)
	RETURNS integer 
AS $$
	SELECT id FROM users WHERE name = usr;
$$ LANGUAGE sql;

-- Function for credential check
CREATE FUNCTION credentials(usr INTEGER, passwd TEXT, ensureAdmin BOOLEAN DEFAULT false)
    RETURNS void
AS $$
    DECLARE 
		rpass TEXT;
		uname TEXT;
    	isAdmin BOOLEAN;
    BEGIN
        PERFORM pg_sleep(0.1);
		-- Obtaining and checking user existence in database
        SELECT name FROM users WHERE usr = id INTO uname;
        SELECT password FROM users WHERE usr = id INTO rpass;
		IF uname IS NULL OR rpass <> md5(uname||passwd) THEN
	   		RAISE EXCEPTION 'Invalid credentials';
		END IF;
		-- Admin privileges check
		IF ensureAdmin THEN
			SELECT admin FROM users WHERE usr = id INTO isAdmin;
			IF NOT isAdmin THEN
				RAISE EXCEPTION 'User is not an admin';
			END IF;
		END IF;
    END
$$ LANGUAGE plpgsql;

-- Function for document privileges check
CREATE FUNCTION permission(usr INTEGER, passwd TEXT, doc INTEGER)
    RETURNS void
AS $$
    DECLARE 
		creator_id INTEGER;
		leasingCount INTEGER;
    BEGIN
		-- Credentials check
        PERFORM credentials(usr, passwd);
		-- Obtaining document creator
		SELECT creator FROM docs WHERE doc = id INTO creator_id;
		-- If user is not a creator, lease check is performed, otherwise exception
		IF creator_id <> usr THEN
	   		SELECT COUNT(*) FROM leasings WHERE usr = lessee AND doc = leasings.doc_id 
	      		INTO leasingCount;
	   		IF leasingCount = 0 THEN
				RAISE EXCEPTION 'User % has no permission to edit document with id %', usr, doc;
	   		END IF;	
		END IF;
    END
$$ LANGUAGE plpgsql;

-- Function for obtaining username
CREATE FUNCTION user_name(uid INT) 
	RETURNS TEXT
AS $$
	SELECT name FROM users WHERE uid = id;
$$ LANGUAGE sql;

-- Function for creating a lease
CREATE FUNCTION lease(doc INT, lessor INT, passwd TEXT, lssee INT)
    RETURNS void
AS $$
	DECLARE
    	ls INTEGER;
    BEGIN
		-- Document privileges check
    	PERFORM permission(lessor, passwd, doc);
		-- User existence check
    	IF user_name(lssee) IS NULL THEN
       		RAISE EXCEPTION 'User % does not exist', lssee;
    	END IF;
		-- Lease existence check
    	SELECT lessee FROM leasings WHERE leasings.lessee = lssee AND leasings.doc_id = doc INTO ls;
    	IF ls IS NOT NULL THEN
    		RAISE EXCEPTION 'User % is already a lessee', ls;
    	END IF;
		-- Lease creation
    	INSERT INTO leasings (lessee, doc_id) VALUES (lssee, doc);
    END
$$ LANGUAGE plpgsql;

-- Function for removing a lease
CREATE FUNCTION remove_lease(doc INT, lessor INT, passwd TEXT, lssee INT)
    RETURNS void
AS $$
    BEGIN
		-- Document privileges check
    	PERFORM permission(lessor, passwd, doc);
		-- User existence check
    	IF user_name(lssee) IS NULL THEN
       		RAISE EXCEPTION 'User % does not exist', lssee;
    	END IF;
		-- Lease deletion
    	DELETE FROM leasings WHERE leasings.lessee = lssee AND leasings.doc_id = doc;
    END
$$ LANGUAGE plpgsql;

-- Function for creating a document
CREATE FUNCTION create_doc(creator INTEGER, passwd TEXT)
	RETURNS INTEGER
AS $$
    DECLARE 
    	did INTEGER;
    BEGIN
		-- User credentials check
       	PERFORM credentials(creator, passwd);
		-- Document creation
       	INSERT INTO docs (creator) VALUES (creator) RETURNING id INTO did;
       	RETURN did;
    END
$$ LANGUAGE plpgsql;

-- Function for removing a document - to use only when attribute batch insertion fails
CREATE FUNCTION remove_doc(doc INTEGER, creator INTEGER, passwd TEXT)
	RETURNS void
AS $$
    BEGIN
		-- Document privileges check
       	PERFORM permission(creator, passwd, doc);
		-- Document deletion
		DELETE FROM docs WHERE docs.id = doc;
    END
$$ LANGUAGE plpgsql;

-- Function for inserting non-container attributes
CREATE FUNCTION set_attr(doc INTEGER, _name TEXT, _value TEXT, _link BOOLEAN, usr INTEGER, passwd TEXT) 
	RETURNS void
AS $$
	DECLARE
    	item INTEGER;
    	attr INTEGER;
	BEGIN
		-- Document privileges check
		PERFORM permission(usr, passwd, doc);
		-- Attribute existence check
		SELECT id FROM attrs WHERE attrs.name = _name  AND holder = doc INTO attr;
		IF attr IS NULL THEN
			-- Value existence check
			SELECT id FROM items WHERE items.value = _value INTO item;
			IF item  IS NULL THEN
				INSERT INTO items (value) VALUES (_value) RETURNING id INTO item;
			END IF;
			INSERT INTO attrs (holder, name, container, link) VALUES (doc, _name, FALSE, _link) RETURNING id INTO attr;
			-- Binding creation
			INSERT INTO bindings (attr_id, item_id, doc_id, operation) VALUES(attr, item, NULL, 0);
		ELSE
			RAISE EXCEPTION 'Attribute % is not container', _name;
		END IF;
  	END
$$ LANGUAGE  plpgsql;

-- Function for removing attributes
CREATE FUNCTION reset_attr(doc_id INTEGER, _name TEXT, usr INTEGER, passwd TEXT)
	RETURNS void
AS $$
	DECLARE
    	attr INTEGER;
	BEGIN
  		-- Document privileges check
    	PERFORM permission(usr, passwd, doc_id);
		-- Attribute existence check
    	SELECT id FROM attrs WHERE attrs.name = _name  AND holder = doc_id INTO attr;
    	IF attr IS NULL THEN
			RAISE EXCEPTION 'Unknown attribute % of document with id %', _name, doc_id;
    	END IF;
		-- Attribute deletion
    	INSERT INTO bindings (attr_id, item_id, doc_id, operation) VALUES(attr, NULL, NULL, 1);
	END  
$$ LANGUAGE  plpgsql;

-- Function for removing attributes from container
CREATE FUNCTION remove_attr(doc_id INTEGER, _name TEXT, _value TEXT, usr INTEGER, passwd TEXT)
	RETURNS void
AS $$
	DECLARE
    	attr INTEGER;
    	cont BOOLEAN;
    	item INTEGER;
  	BEGIN
  		-- Document privileges check
    	PERFORM permission(usr, passwd, doc_id);
		-- Attribute existence and if the attribute is a container check
    	SELECT id, container INTO attr, cont FROM attrs WHERE attrs.name = _name  AND holder = doc_id;
    	IF attr IS NULL THEN
			RAISE EXCEPTION 'Unknown attribute % of document with id %', _name, doc_id;
    	END IF;
    	IF NOT cont THEN
    		RAISE EXCEPTION 'Attribute % of document % is not a container', _name, doc_id;
    	END IF;
		-- Value existence check
    	SELECT id FROM items WHERE items.value = _value INTO item;
    	IF item IS NULL THEN
			RAISE EXCEPTION 'Unknown value % of attribute %', _value, _name;
    	END IF;
		-- Attribute deletion
    	INSERT INTO bindings (attr_id, item_id, doc_id, operation) VALUES(attr, item, NULL, 3);
  	END  
$$ LANGUAGE  plpgsql;

-- Funkce pro vložení kontejnerového atributu
CREATE FUNCTION insert_attr(doc INTEGER, _name TEXT, _value TEXT, _link BOOLEAN, usr INTEGER, passwd TEXT)
	RETURNS void
AS $$
	DECLARE
    	attr INTEGER;
    	cont BOOLEAN;
    	item INTEGER;
  	BEGIN
  		-- Document privileges check
    	PERFORM permission(usr, passwd, doc);
		-- Attribute existence and if the attribute is a container check
    	SELECT id, container INTO attr, cont FROM attrs WHERE attrs.name = _name  AND holder = doc;
    	IF attr IS NULL THEN
    		INSERT INTO attrs (holder, name, container, link) VALUES (doc, _name, TRUE, _link) RETURNING id, container INTO attr, cont;
    	END IF;
		IF NOT cont THEN
    		RAISE EXCEPTION 'Attribute % of document % is not a container', _name, doc;
    	END IF;
		-- Value existence check
    	SELECT id FROM items WHERE items.value = _value INTO item;
    	IF item  IS NULL THEN
        	INSERT INTO items (value) VALUES (_value) RETURNING id INTO item;
    	END IF;
		-- Attribute insertion
    	INSERT INTO bindings (attr_id, item_id, doc_id, operation) VALUES(attr, item, NULL, 2);
  	END  
$$ LANGUAGE  plpgsql;

-- Function for obtaining user's document list
CREATE FUNCTION list_docs (usr INTEGER, passwd TEXT)
	RETURNS TABLE(id INTEGER, name TEXT)
AS $$
	DECLARE
		r RECORD;
    	a RECORD;
	BEGIN
		-- User credentials check
  		PERFORM credentials(usr, passwd);
		-- Temporary table creation
  		CREATE TEMP TABLE temp_docs(id INTEGER, name TEXT);
		-- Browsing distinct document records
  		FOR r IN SELECT DISTINCT docs.id 
  		   		FROM docs 
           		LEFT JOIN leasings ON docs.id = leasings.doc_id 
           		WHERE docs.creator = usr OR leasings.lessee = usr
           		ORDER BY docs.id
  		LOOP
			-- Browsing document attributes to find a name
  			FOR a IN SELECT * FROM scandocs(r.id, now()) LOOP
    			IF a.name = '_id' THEN
        			INSERT INTO temp_docs VALUES (r.id, a.value);
        			EXIT;
        		END IF;
    		END LOOP;
  		END LOOP;
		-- Returning all records and removing temporary table
  		RETURN QUERY SELECT * FROM temp_docs ORDER BY temp_docs.name;
  		DROP TABLE temp_docs;
  		RETURN;
	END
$$ LANGUAGE plpgsql;

-- Function for obtaining lessee list
CREATE FUNCTION list_lessees (doc INTEGER, usr INTEGER, passwd TEXT)
  	RETURNS TABLE(id INTEGER, name TEXT)
AS $$
	DECLARE
  		ctr INTEGER;
	BEGIN
		-- User credentials check
  		PERFORM credentials(usr, passwd);
		-- Creator check
  		SELECT docs.id FROM docs WHERE docs.id = doc AND docs.creator = usr INTO ctr;
  		IF ctr IS NULL THEN
    		RAISE EXCEPTION 'User % is not the creator.', usr;
  		END IF;
		-- Obtaining lessee list
  		RETURN QUERY SELECT users.id, users.name FROM users JOIN leasings ON users.id = leasings.lessee WHERE leasings.doc_id = doc;
	END
$$ LANGUAGE plpgsql;

-- Function for obtaining attribute list according to timestamp
CREATE FUNCTION scandocs (doc INTEGER, deadline TIMESTAMPTZ)
  	RETURNS TABLE(name TEXT, value TEXT, container BOOLEAN, link BOOLEAN, holder INTEGER)
AS $$
	DECLARE
  		r RECORD;
	BEGIN
		-- Temprorary attribute table creation
		CREATE TEMP TABLE temp_attrs(name TEXT, value TEXT, container BOOLEAN, link BOOLEAN, holder INTEGER);
		-- Browsing attributes
  		FOR r in SELECT attrs.name as name,
  				  		attrs.container as container,
                  		attrs.link as link,
                  		attrs.holder as holder,
                  		bindings.btime as btime,
                  		bindings.operation as operation,
                  		docs.id as doc_id,
                  		items.value as value
           			FROM attrs
             		JOIN bindings ON attrs.id = bindings.attr_id
             		LEFT JOIN docs ON bindings.doc_id = docs.id
             		LEFT JOIN items ON bindings.item_id = items.id
           		WHERE attrs.holder = doc AND bindings.btime <= deadline
          		ORDER BY btime ASC
  		LOOP
			-- Inserting container and non-container attributes operation
      		IF r.operation = 0 OR r.operation = 2 THEN
				INSERT INTO temp_attrs VALUES (r.name, r.value, r.container, r.link, r.holder);
			-- Removing attribute operation
      		ELSIF r.operation = 1 THEN
        		DELETE FROM temp_attrs WHERE temp_attrs.name = r.name;
			-- Removing attribute from container operation
      		ELSIF r.operation = 3 THEN
				DELETE FROM temp_attrs WHERE temp_attrs.name = r.name AND temp_attrs.value = r.value;
      		END IF;
  		END LOOP;
		-- Returning all records and removing temporary table
  		RETURN QUERY SELECT * FROM temp_attrs;
  		DROP TABLE temp_attrs;
  		RETURN;
	END
$$ LANGUAGE plpgsql;

-- Function for admin privileges check
CREATE FUNCTION isAdmin(usr INTEGER)
    RETURNS BOOLEAN
AS $$
    SELECT admin FROM users WHERE id = usr;
$$ LANGUAGE sql;

-- Function for document creator check
CREATE FUNCTION isCreator(doc INTEGER, usr INTEGER)
    RETURNS BOOLEAN
AS $$
DECLARE
	creator_id INTEGER;
BEGIN
    SELECT creator FROM docs WHERE id = doc INTO creator_id;
    IF creator_id = usr THEN
    	RETURN TRUE;
    ELSE
    	RETURN FALSE;
    END IF;
END
$$ LANGUAGE plpgsql;

-- Function for obtaining user list
CREATE FUNCTION list_users(usr INTEGER, passwd TEXT)
    RETURNS TABLE(name TEXT)
AS $$
	BEGIN
		-- User credentials check
		PERFORM credentials(usr, passwd);
		-- Returning user list
    	RETURN QUERY SELECT users.name FROM users WHERE id <> usr;
	END;
$$ LANGUAGE plpgsql;

-- Function for obtaining named documents list
CREATE FUNCTION list_all_docs(usr INTEGER, passwd TEXT)
    RETURNS TABLE(id INTEGER, name TEXT)
AS $$
	DECLARE
		r RECORD;
    	a RECORD;
	BEGIN
		-- User credentials check
  		PERFORM credentials(usr, passwd);
		-- Temporary table creation
  		CREATE TEMP TABLE temp_docs(id INTEGER, name TEXT);
		-- Browsing distinct document records
  		FOR r IN SELECT DISTINCT docs.id 
  		   		FROM docs 
           		LEFT JOIN leasings ON docs.id = leasings.doc_id 
           		ORDER BY docs.id
  		LOOP
			-- Browsing document attributes to find name
  			FOR a IN SELECT * FROM scandocs(r.id, now()) LOOP
    			IF a.name = '_id' THEN
        			INSERT INTO temp_docs VALUES (r.id, a.value);
        			EXIT;
        		END IF;
    		END LOOP;
  		END LOOP;
		-- Returning records and removing temporary table
  		RETURN QUERY SELECT * FROM temp_docs ORDER BY temp_docs.name;
  		DROP TABLE temp_docs;
  		RETURN;
	END
$$ LANGUAGE plpgsql;

-- Funtion for obtaining scheme ID
CREATE FUNCTION get_scheme_id (doc INTEGER, usr INTEGER, passwd TEXT)
  RETURNS INTEGER
AS $$
	DECLARE
    	a RECORD;
	BEGIN
		-- User credentials check
  		PERFORM credentials(usr, passwd);
		-- Browsing attributes to find scheme
    	FOR a IN SELECT * FROM scandocs(doc, now()) LOOP
        	IF a.name = '_scheme' THEN
            	RETURN cast(substring(a.value from 2 for (char_length(a.value)-1)) as INTEGER);
            	EXIT;
        	END IF;
    	END LOOP;
    	RETURN -1;
	END
$$ LANGUAGE plpgsql;

-- Function for obtaining document name
CREATE FUNCTION get_name (doc INTEGER, usr INTEGER, passwd TEXT)
  RETURNS TEXT
AS $$
	DECLARE
    	a RECORD;
	BEGIN
		-- User credentials check
  		PERFORM credentials(usr, passwd);
		-- Browsing attributes to find a name
    	FOR a IN SELECT * FROM scandocs(doc, now()) LOOP
        	IF a.name = '_id' THEN
            	RETURN a.value;
            	EXIT;
        	END IF;
    	END LOOP;
    	RETURN '';
	END
$$ LANGUAGE plpgsql;

-- Function for shadow document check
CREATE FUNCTION has_shadow (doc INTEGER, usr INTEGER, passwd TEXT)
  RETURNS BOOLEAN
AS $$
	DECLARE
    	a RECORD;
	BEGIN
		-- User credentials check
  		PERFORM credentials(usr, passwd);
		-- Browsing attributes to find shadow
    	FOR a IN SELECT * FROM scandocs(doc, now()) LOOP
        	IF a.name = '_shadow' THEN
            	RETURN TRUE;
            	EXIT;
        	END IF;
    	END LOOP;
    	RETURN FALSE;
	END
$$ LANGUAGE plpgsql;

------------------------------------------------------------------------

-- Creating first user
SELECT create_first_user('Gandalf');