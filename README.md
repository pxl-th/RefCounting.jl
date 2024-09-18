# RefCounting.jl

<table>
<tr>
  <td>Before</td>
  <td>After</td>
</tr>

<tr>
  <td>
    
  ```julia
  function f()
    x = RefCounted(Ref(1), dtor)
    return
  end
  ```
    
  </td>
  <td>
    
  ```julia
  function f()
    x = RefCounted(Ref(1), dtor)
    decrement!(x)
    return
  end
  ```

  </td>
</tr>
</table>
