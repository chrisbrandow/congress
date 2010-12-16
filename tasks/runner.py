from pymongo import Connection
import sys
import traceback
import datetime
import string

class Database():

    def __init__(self, task_name, host, name):
        """
        Initialize database connection.
        task_name: of the format "name_of_task", which will get transformed to "NameOfTask" internally.
        host: hostname of mongod
        name: collection name
        """
        self.task_name = string.capwords(task_name, "_").replace("_", "")
        self.connection = Connection(host=host)
        self.db = self.connection[name]

    def report(self, status, message):
        """
        Files an unread report for the task runner to read following the conclusion of the task.
        Use the success, warning, and failure methods instead of this method directly.
        """
        self.db['reports'].insert({
          'status': status, 
          'read': False, 
          'message': message, 
          'source': self.task_name, 
          'created_at': datetime.datetime.now()
        })
    
    def success(self, message):
        self.report("SUCCESS", message)
        
    def warning(self, message):
        self.report("WARNING", message)
    
    def failure(self, message):
        self.report("FAILURE", message)
    
    def get_or_initialize(self, collection, criteria):
        """
        If the document (identified by the critiera dict) exists, update its 
        updated_at timestamp and return it.
        If the document does not exist, start a new one with the attributes in 
        criteria, with both created_at and updated_at timestamps.
        """
        document = None
        documents = self.db[collection].find(criteria)
        
        if documents.count() > 0:
          document = documents[0]
        else:
          document = criteria
          document['created_at'] = datetime.datetime.now()
          
        document['updated_at'] = datetime.datetime.now()
        
        return document
    
    def get_or_create(self, collection, criteria, info):
        """
        Performs a get_or_initialize by the criteria in the given collection,
        and then merges the given info dict into the object and saves it immediately.
        """
        document = self.get_or_initialize(collection, criteria)
        document.update(info)
        self.db[collection].save(document)
    
    def __getitem__(self, collection):
        """
        Passes the collection reference right through to the underlying connection.
        """
        return self.db[collection]


task_name = sys.argv[1]
db_host = sys.argv[2]
db_name = sys.argv[3]
db = Database(task_name, db_host, db_name)

try:
    sys.path.append("tasks/%s" % task_name)
    __import__(task_name).run(db)

except Exception as e:
    print e
    exc_type, exc_value, exc_traceback = sys.exc_info()
    db.failure("Fatal Error - %s - %s" % (e, traceback.extract_tb(exc_traceback)))