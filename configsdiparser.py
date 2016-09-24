#############################################################
# SDI is an open source project.
# Licensed under the GNU General Public License v2.
#
# File Description:
#
#
#############################################################

#!/usr/bin/env python

import sys,os

# check python version to import configparser
if sys.version_info[0]<3:
    from ConfigParser import ConfigParser as configparser
else:
    from configparser import configparser

class configsdiparser:

    def __init__(self, conf=os.path.dirname(sys.argv[0]) + '/' + 'sdi.conf'):
        # get the correct conf path
        dirname = os.path.dirname(sys.argv[0])
        self.conffilepath = conf

        # define default variable values
        self.defaults = {
            'general':   {'prefix': dirname,
                          'cmd dir': '%(prefix)s/cmds',
                          'cmd general': '%(cmd dir)s/general',
                          'tmp dir': '/tmp/sdi',
                          'node db': '%(tmp dir)s/nodedb',
                          'pid dir': '%(tmp dir)s/pids',
                          'pid dir sys': '%(pid dir)s/system',
                          'pid dir hosts': '%(pid dir)s/hosts',
                          'lock dir': '%(tmp dir)s/locks',
                          'hooks':  '%(prefix)s/commands-enabled',
                          'shooks': '%(prefix)s/states-enabled',
                          'sumhooks': '%(prefix)s/summaries-enabled',
                          'launch delay': '0.05',
                          'kill tout': '30',
                          'log': '%(prefix)s/sdi.log',
                          'fifo dir':  '%(tmp dir)s/fifos',
                          'sfifo': '%(fifo dir)s/states.fifo'},
            'server':    {'ws user': 'user',
                          'ws pass': 'password',
                          'ws addr': '54.232.228.140',
                          'ws port': '12345'},
            'ssh':       {'sdiuser': 'root',
                          'timeout': '240',
                          'ssh port': '22',
                          'sshopt[0]': 'PreferredAuthentications=publickey',
                          'sshopt[1]': 'StrictHostKeychecking=no',
                          'sshopt[2]': 'ConnectTimeout=%(timeout)s',
                          'sshopt[3]': 'TCPKeepAlive=yes',
                          'sshopt[4]': 'ServerAliveCountMax=3',
                          'sshopt[5]': 'ServerAliveInterval=100'},
            'web':       {'prefix': dirname,
                          'web mode': 'true',
                          'sdi web': 'sdiweb',
                          'classes dir': '%(prefix)s/CLASSES',
                          'class name': 'MACHINES',
                          'wwwdir': 'www',
                          'host columnname': 'Hostname',
                          'default columns': 'Hostname,Uptime,Status'},
            'data':      {'prefix': dirname,
                          'data dir': '%(prefix)s/data',
                          'use fast data dir': 'no',
                          'fast data dir': '/dev/shm/sdi/data',
                          'data sync interval': '3',
                          'data history format': '%Y.%m'},
            'send file': {'send limit': '1'},
            'modules':   {'prefix': dirname,
                          'send dir': '%(prefix)s/modules/send',
                          'default send': 'ssh.sh',
                          'receive dir': '%(prefix)s/modules/receive',
                          'default receive': 'cat.sh'}
        }

        self.config = configparser()

        # read the config file
        try:
            self.config.read(self.conffilepath)
        except:
            print 'error: bad config file'
            sys.exit(1)

        # Load default config values
        self._load_default_options()

        # Write back sdi.conf if it does not exist
        if not os.path.exists(dirname+'/sdi.conf'):
            self.config.write(open(dirname+'/sdi.conf','w'))

    def printvars(self, output, sections):
        if sections[0] == 'all':
            sections = self.config.sections()
        for sec in sections:
            for var,value in self.config.items(sec):
                value = value.replace('"','')
                if output=='js':
                  print 'var %s="%s";' %(var.lower().replace(' ',''),value),
                if output=='shell':
                  print '%s="%s" ' %(var.upper().replace(' ',''),value),

    def get(self, section, var):
        return self.config.get(section, var)

    def _sshopts_to_posix(self):
        newopt = ""
        for key, value in self.config.items("ssh",1):
            if key.startswith('sshopt'):
                newopt += "-o %s " % value.replace('"','')
                self.config.remove_option("ssh",key)
        self.config.set("ssh","sshopts",newopt)

    def _load_default_options(self):
       for default_sec, default_values in self.defaults.items():
            if not self.config.has_section(default_sec):
                self.config.add_section(default_sec)
            for opt, value in default_values.items():
                if not self.config.has_option(default_sec,opt):
                    self.config.set(default_sec,opt,value)
            if default_sec == "ssh":
                self._sshopts_to_posix()

if __name__ == '__main__':
    if len(sys.argv)<=2:
        sys.exit(1)

    parse = configsdiparser(sys.argv[1])
    parse.printvars(sys.argv[2],sys.argv[3:])
