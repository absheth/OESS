document.addEventListener('DOMContentLoaded', function() {
  let url = new URL(window.location.href);
  let entityID = url.searchParams.get('entity_id');

  loadUserMenu().then(function() {
      loadEntityList(entityID);
  });

  let addToConnection = document.querySelector('#entity-connect-existing');
  addToConnection.addEventListener('click', addToConnectionCallback);

  let addToConnectionCancel = document.querySelector('#add-to-connection-cancel');
  addToConnectionCancel.addEventListener('click', addToConnectionCancelCallback);
});

// Called when the 'Add to existing Connection' button is
// pressed. Presents the user with a list of all connections to which
// the current entity may be added.
async function addToConnectionCallback() {
    let addEndpointModal = $('#add-to-connection-modal');
    addEndpointModal.modal('show');

    let connections = await getVRFs(session.data.workgroup_id);
    let html = '';

    let entityName = document.querySelector('#entity-name');

    for (let i = 0; i < connections.length; i++) {
        let conn = connections[i];
        html += `
<tr>
  <td><a href="?action=modify_cloud&vrf_id=${conn.vrf_id}&prepop_vrf_id=${entityName.dataset.id}"><b>${conn.name}</b></a></td>
  <td>${conn.vrf_id}</td>
  <td>${conn.created_by.email}</td>
</tr>
`;
    }

    if (connections.length === 0) {
        document.querySelector('#add-to-connection-list').innerHTML = '<p>No existing connections found. Create a new L3VPN to connect to this Entity.</p><br/>'
    } else {
        document.querySelector('#add-to-connection-list').innerHTML = '<table class="table">' + html + '</table>';
    }
}

async function addToConnectionCancelCallback() {
    let addEndpointModal = $('#add-to-connection-modal');
    addEndpointModal.modal('hide');
}

async function loadEntityList(parentEntity=null) {
    let entity = await getEntities(session.data.workgroup_id, parentEntity);
    let entitiesList = document.querySelector('#entity-list');
 
    let edit_entity_btn = document.querySelector('#edit-entity');
    let add_user_btn = document.querySelector('#user-dropdown');

    edit_entity_btn.style.display = 'none';
    add_user_btn.style.display = 'none';

    let logoURL = entity.logo_url || '../media/default_entity.png';
    let description = entity.description;
    let name = entity.name;
    let entityID = entity.entity_id;

    let parent = null;
    if ('parents' in entity && entity.parents.length > 0) {
        parent = entity.parents[0];
    }

    let logo = document.querySelector('.entity-logo');
    logo.setAttribute('src', logoURL);

    let entityName = document.querySelector('#entity-name');
    entityName.dataset.id = entityID;
    if (parent !== null) {
        entityName.innerHTML = `${name} <small>of <a href="#" onclick="loadEntityList(${parent.entity_id})">${parent.name}</a></small>`;
    } else {
        entityName.innerHTML = name;
    }

    let entityConnect = document.querySelector('#entity-connect');
    if (parent !== null) {
        entityConnect.style.display = 'block';
        entityConnect.innerHTML = `Create new connection to ${name}`;
        entityConnect.addEventListener('click', function() {
                window.location.href = `?action=provision_cloud&prepop_vrf_id=${entityID}`;
            }, false);
    } else {
        entityConnect.style.display = 'none';
    }

    let entityDescription = document.querySelector('#entity-description');
    entityDescription.innerHTML = description;

    let header = document.querySelector('#entity-header');
    header.style.flexDirection = 'column';

    let elogo = document.querySelector('#entity-logo');
    let ename = document.querySelector('#entity-name');
    if (entityID == "1") {
        elogo.style.display = 'none';
        ename.style.display = 'none';
        header.innerHTML = `<h1>Network Entities</h1>
            <p>Browse connected network entities here. Once you've located a network you'd like to connect with, you may use the provided links to add the network to an existing Layer3 VPN or use the network as the basis for a new VPN.</p><p>To create a new entity, please <a href="mailto:[% admin_email %]?SUBJECT=System Support: OESS Entity Creation Request">contact</a> your OESS administrator.</p>`;
    } else {
        header.innerHTML = '';
        elogo.style.display = 'block';
        ename.style.display = 'block';
    }

    let path   = sessionStorage.getItem('phone-crumb');
    let cpath  = '';

    let entityCrumbs = document.querySelector('#entity-crumbs');
    let entityCrumbsString = '';


    let entityNav = '';

    if (parent === null || !path) {
        path = '[]';
        sessionStorage.setItem('phone-crumb', path);
    } else {
        let crumbs = JSON.parse(path);
        let found  = 0;

        for (let i = 0; i < crumbs.length; i++) {
            if (crumbs[i].name === parent.name) {
                found = 1;
                crumbs = crumbs.splice(i, 1);
                break;
            }
        }
        if (!found && parent !== null) {
            crumbs.push({name: parent.name, id: parent.entity_id});
        }

        cpath = crumbs.map(function(c){ return c.name; }).join(' / ');
        sessionStorage.setItem('phone-crumb', JSON.stringify(crumbs));

        if (parent !== null && entity.children.length === 0) {
            entityNav += `<li role="presentation" onclick="loadEntityList(${parent.entity_id})"><a href="#">Go back</a></li>`;
        }

        crumbs.forEach(function(c) {
            entityCrumbsString += `<li><a href="#" onclick="loadEntityList(${c.id})">${c.name}</a></li>`;
        });

    }

    entityCrumbsString += `<li class="active">${name}</li>`;
    entityCrumbs.innerHTML = entityCrumbsString;

    let entityActions = document.querySelector('#entity-actions');
    if (entity.interfaces.length > 0) {
        entityActions.style.display = 'flex';
    } else {
        entityActions.style.display = 'none';
    }

    entity.children.forEach(function(entity) {
        let childLi  = `<li role="presentation" onclick="loadEntityList(${entity.entity_id})"><a href="#">${entity.name}</a></li>`;
        entityNav += childLi;
    });
    entitiesList.innerHTML = entityNav;

    if (entity.contacts.length < 1) {
        document.querySelector('#entity-contacts-title').style.display = 'none';
    } else {
        document.querySelector('#entity-contacts-title').style.display = 'block';
    }

    let user = await getCurrentUser();
    let url2 = `[% path %]services/entity.cgi?action=get_valid_users&entity_id=${entityID}`;
    const resp = await fetch(url2, {method: 'get', credentials: 'include'}); 
    const data = await resp.json();
    var valid_users = data.results;
    let entityContacts = '';
    let contact_ids = [];
    entity.contacts.forEach(function(contact) {
            console.log("contact");
            console.log(contact);
            var user_id = contact.user_id;
            contact_ids.push(user_id);
	    entityContacts += `<p class="entity-contact"><b>${contact.first_name} ${contact.last_name}</b>`;
            if (valid_users.includes( user.user_id)){
              entityContacts += `<sup style = "cursor:pointer" onclick='remove_user(${user_id}, ${entity.entity_id})'> &#10006</sup>`;
            }
            
            entityContacts += `<br/>${contact.email}<br/></p>`;
    });
    document.querySelector('#entity-contacts').innerHTML = entityContacts;

    if (valid_users.includes(user.user_id)){
          let edit_entity_btn = document.querySelector('#edit-entity');
          edit_entity_btn.style.display = 'inline-block';
          edit_entity_btn.onclick = function(){
            window.location.href = `[% path %]new/index.cgi?action=edit_entity&entity_id=${entityID}`;
          };

          let user_list = document.querySelector('#user-list');
          user_list.innerHTML ="";
          add_user_btn.style.display = 'block';
          let users_url = `[% path %]services/data.cgi?action=get_users`;
          const users_resp = await fetch(users_url, {method:'get', credentials:'include'});
          var users = await users_resp.json();
          users = users['results'];
          console.log(users);
          let i =0;
          for (i =0 ; i < users.length; i++){
            var ele = document.createElement("A");
            let user_id = users[i]['user_id'];
            if (!contact_ids.includes(user_id)){
              ele.onclick = function(){ add_user(user_id, entityID)};
              var t = document.createTextNode(users[i]['first_name'] + " "  +users[i]['family_name']);
              ele.appendChild(t);
              user_list.appendChild(ele);
              console.log(users[i]['first_name']);
            }
          }
   }
}

function showDropdown() {
  document.getElementById("user-list").classList.toggle("show");
}

function filterFunction() {
  var input, filter, ul, li, a, i;
  input = document.getElementById("user-search");
  filter = input.value.toUpperCase();
  div = document.getElementById("user-list");
  a = div.getElementsByTagName("a");
  for (i = 0; i < a.length; i++) {
    txtValue = a[i].textContent || a[i].innerText;
    if (txtValue.toUpperCase().indexOf(filter) > -1) {
      a[i].style.display = "";
    } else {
      a[i].style.display = "none";
    }
  }
}

// Add user to entity
async function add_user(user_id, entityID){
  const url = `[% path %]services/entity.cgi?action=add_user&entity_id=${entityID}&user_id=${user_id}`;
  const response = await fetch(url, {method:'get', credentials:'include'});
  const data = await response.json();
  console.log(data);
  await loadEntityList(entityID);
 }

async function remove_user(user_id, entityID){
  const url = `[% path %]services/entity.cgi?action=remove_user&entity_id=${entityID}&user_id=${user_id}`;
  const response = await fetch(url, {method:'get', credentials:'include'});
  const data = await response.json;

  await loadEntityList(entityID);
}

